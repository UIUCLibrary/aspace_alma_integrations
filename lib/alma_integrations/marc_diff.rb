require_relative 'settings'
require_relative 'marc_record'
require_relative 'marc_normalizer'
require_relative 'marc_labels'

module AlmaIntegrations
  # Compares the MARC record currently in Alma against the record that would be
  # written to Alma, and describes what a cataloguer would lose or see change.
  #
  # Vocabulary used throughout the report:
  #
  #   loss      Data that exists in Alma and would simply be gone: a whole field
  #             instance that disappears, or a subfield dropped from a field that
  #             otherwise survives.
  #   change    Data that survives in some form but with a different value.
  #   addition  Data in the outgoing record with no counterpart in Alma.
  #
  # Repeated fields are compared as multisets rather than pairwise by position,
  # because MARC does not guarantee the order of repeated fields and a positional
  # comparison would report spurious changes on every reordered record.
  class MarcDiff

    # Minimum overlap before two instances of the same tag are considered to be
    # "the same field, edited" rather than one field removed and another added.
    SIMILARITY_THRESHOLD = 0.5

    # Characters that mean "no data" in a fixed-length control field.
    NO_DATA_CHARACTERS = [' ', '|', '^', '#'].freeze

    def initialize(settings = nil)
      @settings = settings.is_a?(Settings) ? settings : Settings.new(settings || {})
      @normalizer = MarcNormalizer.new(:whitespace => @settings[:normalize_whitespace],
                                       :punctuation => @settings[:normalize_punctuation],
                                       :casing => @settings[:normalize_case])
      @ignored_tags = Array(@settings[:ignored_tags]).map(&:to_s)
      @preserved_tags = Array(@settings[:preserved_tags]).map(&:to_s)
      @ignore_value_patterns = Array(@settings[:ignore_value_patterns])
    end

    def diff(alma_source, outgoing_source)
      alma = MarcRecord.parse(alma_source)
      outgoing = MarcRecord.parse(outgoing_source)

      alma_fields, ignored_alma = partition_enrichment(alma.fields)
      outgoing_fields, = partition_enrichment(outgoing.fields)

      alma_by_tag = group_by_tag(alma_fields)
      outgoing_by_tag = group_by_tag(outgoing_fields)

      entries = []

      leader_entry = diff_leader(alma.leader, outgoing.leader)
      entries << leader_entry if leader_entry

      (alma_by_tag.keys | outgoing_by_tag.keys).sort.each do |tag|
        entry = diff_tag(tag, alma_by_tag[tag] || [], outgoing_by_tag[tag] || [])
        entries << entry if entry
      end

      alma_tag_counts = alma_by_tag.each_with_object({}) { |(tag, fields), out| out[tag] = fields.length }
      alma_tag_counts[MarcLabels::LEADER] = 1 unless alma.leader.nil?

      outgoing_tag_counts = outgoing_by_tag.each_with_object({}) { |(tag, fields), out| out[tag] = fields.length }
      outgoing_tag_counts[MarcLabels::LEADER] = 1 unless outgoing.leader.nil?

      counted = entries.reject { |entry| entry['ignored'] }

      {
        'fields' => entries,
        'alma_tag_counts' => alma_tag_counts,
        'outgoing_tag_counts' => outgoing_tag_counts,
        'enrichment_fields_ignored' => ignored_alma.length,
        'has_loss' => counted.any? { |entry| entry['has_loss'] },
        'has_change' => counted.any? { |entry| entry['has_change'] },
        'has_addition' => counted.any? { |entry| entry['has_addition'] }
      }
    end

    # Pairs up the individual field instances of the two records so they can be
    # shown one opposite the other. #diff answers "what would change"; #align
    # answers "which line sits opposite which line". Both run the same matching,
    # so the highlighted view and the report can never disagree.
    #
    # Rows come back ordered by tag, and within a tag: the instances that
    # survive unchanged, then those that are edited, then those that are lost,
    # then those that are added. Enrichment fields that #diff quietly sets aside
    # are still returned, marked as ignored, so the rendered record is the whole
    # record rather than a silently abridged one.
    def align(alma_source, outgoing_source)
      alma = MarcRecord.parse(alma_source)
      outgoing = MarcRecord.parse(outgoing_source)

      rows = []

      leader_row = align_leader(alma.leader, outgoing.leader)
      rows << leader_row if leader_row

      alma_by_tag = group_by_tag(alma.fields)
      outgoing_by_tag = group_by_tag(select_comparable(outgoing.fields))

      (alma_by_tag.keys | outgoing_by_tag.keys).sort.each do |tag|
        comparable, enrichment = partition_enrichment(alma_by_tag[tag] || [])

        enrichment.each { |field| rows << enrichment_row(tag, field) }
        rows.concat(align_tag(tag, comparable, outgoing_by_tag[tag] || []))
      end

      {
        'rows' => rows,
        'counts' => rows.each_with_object(Hash.new(0)) { |row, out| out[row['status']] += 1 }
      }
    end

    private

    def select_comparable(fields)
      comparable, = partition_enrichment(fields)
      comparable
    end

    def align_leader(alma_leader, outgoing_leader)
      return nil if alma_leader.nil? && outgoing_leader.nil?

      tag = MarcLabels::LEADER
      alma = alma_leader.nil? ? nil : { 'tag' => tag, 'value' => alma_leader, 'display' => "#{tag}  #{alma_leader}" }
      outgoing = outgoing_leader.nil? ? nil : { 'tag' => tag, 'value' => outgoing_leader, 'display' => "#{tag}  #{outgoing_leader}" }

      return row(tag, 'added', :outgoing => outgoing) if alma.nil?
      return row(tag, 'lost', :alma => alma) if outgoing.nil?

      positions = diff_positions(tag, alma_leader, outgoing_leader)
      status = positions.empty? ? 'unchanged' : 'changed'

      row(tag, status, :alma => alma, :outgoing => outgoing, :positions => positions)
    end

    def align_tag(tag, alma_fields, outgoing_fields)
      if control_tag?(alma_fields, outgoing_fields)
        align_control_tag(tag, alma_fields, outgoing_fields)
      else
        align_data_tag(tag, alma_fields, outgoing_fields)
      end
    end

    def align_control_tag(tag, alma_fields, outgoing_fields)
      pairs = [alma_fields.length, outgoing_fields.length].min
      rows = []

      (0...pairs).each do |index|
        alma_field = alma_fields[index]
        outgoing_field = outgoing_fields[index]
        positions = diff_positions(tag, alma_field.value, outgoing_field.value)

        rows << row(tag, positions.empty? ? 'unchanged' : 'changed',
                    :alma => alma_field.to_h,
                    :outgoing => outgoing_field.to_h,
                    :positions => positions)
      end

      alma_fields[pairs..-1].to_a.each { |field| rows << row(tag, 'lost', :alma => field.to_h) }
      outgoing_fields[pairs..-1].to_a.each { |field| rows << row(tag, 'added', :outgoing => field.to_h) }

      rows
    end

    def align_data_tag(tag, alma_fields, outgoing_fields)
      identical, alma_left, outgoing_left = match_identical(alma_fields, outgoing_fields)
      edited, alma_left, outgoing_left = match_similar(alma_left, outgoing_left)

      rows = identical.map do |alma_field, outgoing_field|
        row(tag, 'unchanged',
            :alma => alma_field.to_h,
            :outgoing => outgoing_field.to_h,
            :alma_parts => plain_parts(alma_field),
            :outgoing_parts => plain_parts(outgoing_field))
      end

      rows.concat(edited.map { |alma_field, outgoing_field| align_edited(tag, alma_field, outgoing_field) })

      alma_left.each do |field|
        rows << row(tag, 'lost', :alma => field.to_h, :alma_parts => plain_parts(field, 'lost'))
      end

      outgoing_left.each do |field|
        rows << row(tag, 'added', :outgoing => field.to_h, :outgoing_parts => plain_parts(field, 'added'))
      end

      rows
    end

    # An edited instance is reported subfield by subfield, with each side's
    # subfields already labelled, so the view has nothing left to work out. A
    # changed subfield carries its counterpart's value so the view can highlight
    # the differing words within it.
    def align_edited(tag, alma_field, outgoing_field)
      pairing = pair_subfields(alma_field, outgoing_field)

      alma_parts = plain_parts(alma_field, 'unchanged')
      outgoing_parts = plain_parts(outgoing_field, 'unchanged')

      pairing['changed'].each do |a_index, b_index|
        alma_parts[a_index]['status'] = 'changed'
        alma_parts[a_index]['counterpart'] = outgoing_field.subfields[b_index].last
        outgoing_parts[b_index]['status'] = 'changed'
        outgoing_parts[b_index]['counterpart'] = alma_field.subfields[a_index].last
      end

      pairing['lost'].each { |a_index| alma_parts[a_index]['status'] = 'lost' }
      pairing['added'].each { |b_index| outgoing_parts[b_index]['status'] = 'added' }

      row(tag, 'changed',
          :alma => alma_field.to_h,
          :outgoing => outgoing_field.to_h,
          :alma_parts => alma_parts,
          :outgoing_parts => outgoing_parts,
          :indicators_changed => alma_field.indicators != outgoing_field.indicators,
          :subfields => diff_subfields(alma_field, outgoing_field))
    end

    def plain_parts(field, status = 'unchanged')
      return [] if field.control?

      field.subfields.map do |code, value|
        { 'code' => code.to_s, 'value' => value, 'status' => status }
      end
    end

    # Alma's generated 035s are not part of the record a cataloguer maintains,
    # so they are shown but never flagged.
    def enrichment_row(tag, field)
      row(tag, 'ignored', :alma => field.to_h, :alma_parts => plain_parts(field, 'ignored'), :enrichment => true)
    end

    def row(tag, status, attributes = {})
      {
        'tag' => tag,
        'label' => MarcLabels.tag_label(tag),
        'status' => status,
        'ignored' => @ignored_tags.include?(tag),
        'preserved' => @preserved_tags.include?(tag),
        'enrichment' => false,
        'alma' => nil,
        'outgoing' => nil,
        'alma_parts' => [],
        'outgoing_parts' => [],
        'positions' => [],
        'indicators_changed' => false,
        'subfields' => nil
      }.merge(attributes.each_with_object({}) { |(key, value), out| out[key.to_s] = value })
    end

    # Alma's multi-record GET adds 035 fields carrying the Network Zone and
    # Community Zone identifiers. They are generated at retrieval time rather
    # than stored on the record, so comparing against them would report a
    # phantom 035 loss for every single record in the audit.
    def partition_enrichment(fields)
      return [fields, []] if @ignore_value_patterns.empty?

      fields.partition { |field| !enrichment?(field) }
    end

    def enrichment?(field)
      return false if field.control?

      field.subfields.any? do |_, value|
        @ignore_value_patterns.any? { |pattern| pattern.match?(value.to_s) }
      end
    end

    def group_by_tag(fields)
      fields.each_with_object({}) do |field, out|
        (out[field.tag] ||= []) << field
      end
    end

    def diff_leader(alma_leader, outgoing_leader)
      return nil if alma_leader.nil? && outgoing_leader.nil?

      tag = MarcLabels::LEADER

      if alma_leader.nil?
        return build_entry(tag, 0, 1, 0, [], [{ 'tag' => tag, 'value' => outgoing_leader, 'display' => "#{tag}  #{outgoing_leader}" }], [])
      end

      if outgoing_leader.nil?
        return build_entry(tag, 1, 0, 0, [{ 'tag' => tag, 'value' => alma_leader, 'display' => "#{tag}  #{alma_leader}" }], [], [])
      end

      positions = diff_positions(tag, alma_leader, outgoing_leader)
      return nil if positions.empty?

      modified = [{
        'alma' => { 'tag' => tag, 'value' => alma_leader },
        'outgoing' => { 'tag' => tag, 'value' => outgoing_leader },
        'positions' => positions
      }]

      build_entry(tag, 1, 1, 0, [], [], modified)
    end

    def diff_tag(tag, alma_fields, outgoing_fields)
      if control_tag?(alma_fields, outgoing_fields)
        diff_control_tag(tag, alma_fields, outgoing_fields)
      else
        diff_data_tag(tag, alma_fields, outgoing_fields)
      end
    end

    def control_tag?(alma_fields, outgoing_fields)
      candidates = alma_fields + outgoing_fields
      !candidates.empty? && candidates.all?(&:control?)
    end

    # Control fields are fixed-length strings, so they are compared position by
    # position and the differing runs are reported with their MARC labels.
    def diff_control_tag(tag, alma_fields, outgoing_fields)
      pairs = [alma_fields.length, outgoing_fields.length].min
      lost = alma_fields[pairs..-1].to_a.map(&:to_h)
      added = outgoing_fields[pairs..-1].to_a.map(&:to_h)
      modified = []
      unchanged = 0

      (0...pairs).each do |index|
        alma_field = alma_fields[index]
        outgoing_field = outgoing_fields[index]
        positions = diff_positions(tag, alma_field.value, outgoing_field.value)

        if positions.empty?
          unchanged += 1
          next
        end

        modified << {
          'alma' => alma_field.to_h,
          'outgoing' => outgoing_field.to_h,
          'positions' => positions
        }
      end

      build_entry(tag, alma_fields.length, outgoing_fields.length, unchanged, lost, added, modified)
    end

    def diff_data_tag(tag, alma_fields, outgoing_fields)
      identical, alma_left, outgoing_left = match_identical(alma_fields, outgoing_fields)
      modified_pairs, alma_left, outgoing_left = match_similar(alma_left, outgoing_left)

      modified = modified_pairs.map do |alma_field, outgoing_field|
        {
          'alma' => alma_field.to_h,
          'outgoing' => outgoing_field.to_h,
          'subfields' => diff_subfields(alma_field, outgoing_field)
        }
      end

      build_entry(tag,
                  alma_fields.length,
                  outgoing_fields.length,
                  identical.length,
                  alma_left.map(&:to_h),
                  outgoing_left.map(&:to_h),
                  modified)
    end

    # Step one: take out every field that survives byte-for-byte (after
    # normalisation), treating repeats as a multiset. Returns the surviving
    # pairs rather than a bare count, because the side-by-side view needs to
    # know which Alma instance sits opposite which outgoing instance.
    def match_identical(alma_fields, outgoing_fields)
      available = {}
      outgoing_fields.each_with_index do |field, index|
        (available[field_key(field)] ||= []) << index
      end

      matched_outgoing = {}
      matched = []
      alma_left = []

      alma_fields.each do |field|
        key = field_key(field)
        index = available[key] && available[key].shift

        if index.nil?
          alma_left << field
        else
          matched_outgoing[index] = true
          matched << [field, outgoing_fields[index]]
        end
      end

      outgoing_left = outgoing_fields.each_with_index.reject { |_, index| matched_outgoing[index] }.map(&:first)

      [matched, alma_left, outgoing_left]
    end

    # Step two: of what is left, pair up the instances that are recognisably the
    # same field edited rather than one removed and an unrelated one added.
    def match_similar(alma_fields, outgoing_fields)
      return [[], alma_fields, outgoing_fields] if alma_fields.empty? || outgoing_fields.empty?

      candidates = []
      alma_fields.each_with_index do |alma_field, a_index|
        outgoing_fields.each_with_index do |outgoing_field, b_index|
          score = similarity(alma_field, outgoing_field)
          candidates << [score, a_index, b_index] if score >= SIMILARITY_THRESHOLD
        end
      end

      # Highest scoring pairs win; ties resolve by original order so the result is
      # deterministic.
      candidates.sort_by! { |score, a_index, b_index| [-score, a_index, b_index] }

      used_alma = {}
      used_outgoing = {}
      pairs = []

      candidates.each do |_, a_index, b_index|
        next if used_alma[a_index] || used_outgoing[b_index]

        used_alma[a_index] = true
        used_outgoing[b_index] = true
        pairs << [a_index, b_index]
      end

      pairs.sort_by! { |a_index, _| a_index }

      matched = pairs.map { |a_index, b_index| [alma_fields[a_index], outgoing_fields[b_index]] }
      alma_left = alma_fields.each_with_index.reject { |_, index| used_alma[index] }.map(&:first)
      outgoing_left = outgoing_fields.each_with_index.reject { |_, index| used_outgoing[index] }.map(&:first)

      [matched, alma_left, outgoing_left]
    end

    def similarity(alma_field, outgoing_field)
      alma_parts = normalized_subfields(alma_field)
      outgoing_parts = normalized_subfields(outgoing_field)
      return 0.0 if alma_parts.empty? && outgoing_parts.empty?

      shared = multiset_intersection_size(alma_parts, outgoing_parts)
      score = (2.0 * shared) / (alma_parts.length + outgoing_parts.length)

      # A shared $a is strong evidence that this is the same field, even when the
      # rest of the subfields were rewritten.
      alma_a = alma_parts.select { |code, _| code == 'a' }.map(&:last)
      outgoing_a = outgoing_parts.select { |code, _| code == 'a' }.map(&:last)
      unless alma_a.empty? || outgoing_a.empty?
        score = [score, 0.75].max unless (alma_a & outgoing_a).empty?
      end

      score
    end

    # Pairs the subfields of two instances of the same field. Both the report
    # (#diff_subfields) and the side-by-side view (#align) are built from this
    # one pairing, so the two presentations can never disagree about which
    # subfield changed into which.
    #
    # Returned in index terms, so callers can reach back to the original
    # subfield values rather than the normalised ones used for matching.
    def pair_subfields(alma_field, outgoing_field)
      alma_parts = normalized_subfields(alma_field)
      outgoing_parts = normalized_subfields(outgoing_field)

      available = {}
      outgoing_parts.each_with_index { |part, index| (available[part] ||= []) << index }

      matched_outgoing = {}
      unchanged = []
      alma_left = []

      alma_parts.each_with_index do |part, index|
        match = available[part] && available[part].shift
        if match.nil?
          alma_left << index
        else
          matched_outgoing[match] = true
          unchanged << [index, match]
        end
      end

      outgoing_left = (0...outgoing_parts.length).reject { |index| matched_outgoing[index] }

      # Within a field, a leftover on each side sharing a subfield code is a
      # changed value; anything still unpaired is a genuine loss or addition.
      outgoing_by_code = outgoing_left.group_by { |index| outgoing_parts[index].first }

      changed = []
      lost = []

      alma_left.each do |a_index|
        code = alma_parts[a_index].first
        b_index = outgoing_by_code[code] && outgoing_by_code[code].shift

        if b_index.nil?
          lost << a_index
        else
          changed << [a_index, b_index]
        end
      end

      added = outgoing_by_code.values.flatten.sort

      { 'unchanged' => unchanged, 'changed' => changed, 'lost' => lost, 'added' => added }
    end

    def diff_subfields(alma_field, outgoing_field)
      pairing = pair_subfields(alma_field, outgoing_field)

      changed = pairing['changed'].map do |a_index, b_index|
        {
          'code' => alma_field.subfields[a_index].first.to_s,
          'alma' => alma_field.subfields[a_index].last,
          'outgoing' => outgoing_field.subfields[b_index].last
        }
      end

      added = pairing['added'].map { |b_index| subfield_hash(outgoing_field, b_index) }

      {
        'lost' => pairing['lost'].map { |a_index| subfield_hash(alma_field, a_index) },
        'added' => added.sort_by { |sub| sub['code'].to_s },
        'changed' => changed,
        'indicators_changed' => alma_field.indicators != outgoing_field.indicators,
        'alma_indicators' => alma_field.indicators,
        'outgoing_indicators' => outgoing_field.indicators
      }
    end

    def subfield_hash(field, index)
      code, value = field.subfields[index]
      { 'code' => code, 'value' => value }
    end

    def normalized_subfields(field)
      return [] if field.control?

      field.subfields.map { |code, value| [code.to_s, @normalizer.call(value)] }
    end

    def field_key(field)
      if field.control?
        [field.tag, :control, @normalizer.call(field.value)]
      else
        [field.tag, field.indicators, normalized_subfields(field)]
      end
    end

    def multiset_intersection_size(left, right)
      counts = Hash.new(0)
      left.each { |item| counts[item] += 1 }

      right.count do |item|
        if counts[item] > 0
          counts[item] -= 1
          true
        else
          false
        end
      end
    end

    def diff_positions(tag, alma_value, outgoing_value)
      alma_value = alma_value.to_s
      outgoing_value = outgoing_value.to_s
      mechanical = MarcLabels.mechanical_positions(tag)
      length = [alma_value.length, outgoing_value.length].max

      runs = []
      current = nil

      (0...length).each do |index|
        alma_char = alma_value[index] || ' '
        outgoing_char = outgoing_value[index] || ' '

        if alma_char == outgoing_char || mechanical.include?(index)
          runs << current if current
          current = nil
          next
        end

        kind = (no_data?(outgoing_char) && !no_data?(alma_char)) ? 'loss' : 'change'

        if current && current['kind'] == kind && current['end'] == index - 1
          current['end'] = index
          current['alma'] << alma_char
          current['outgoing'] << outgoing_char
        else
          runs << current if current
          current = {
            'kind' => kind,
            'start' => index,
            'end' => index,
            'alma' => alma_char.dup,
            'outgoing' => outgoing_char.dup
          }
        end
      end

      runs << current if current

      runs.each do |run|
        label = MarcLabels.position_label(tag, run['start'], run['end'])
        run['label'] = label unless label.nil?
      end

      runs
    end

    def no_data?(character)
      NO_DATA_CHARACTERS.include?(character)
    end

    def build_entry(tag, alma_count, outgoing_count, unchanged_count, lost, added, modified)
      subfield_losses = modified.sum { |pair| pair.dig('subfields', 'lost')&.length.to_i }
      position_losses = modified.sum { |pair| Array(pair['positions']).count { |run| run['kind'] == 'loss' } }
      subfield_changes = modified.sum do |pair|
        pair.dig('subfields', 'changed')&.length.to_i +
          (pair.dig('subfields', 'indicators_changed') ? 1 : 0)
      end
      position_changes = modified.sum { |pair| Array(pair['positions']).count { |run| run['kind'] == 'change' } }
      subfield_additions = modified.sum { |pair| pair.dig('subfields', 'added')&.length.to_i }

      has_loss = !lost.empty? || subfield_losses > 0 || position_losses > 0
      has_change = subfield_changes > 0 || position_changes > 0
      has_addition = !added.empty? || subfield_additions > 0

      return nil unless has_loss || has_change || has_addition

      {
        'tag' => tag,
        'label' => MarcLabels.tag_label(tag),
        'ignored' => @ignored_tags.include?(tag),
        'preserved' => @preserved_tags.include?(tag),
        'alma_count' => alma_count,
        'outgoing_count' => outgoing_count,
        'unchanged_count' => unchanged_count,
        'full_loss' => alma_count > 0 && outgoing_count.zero?,
        'has_loss' => has_loss,
        'has_change' => has_change,
        'has_addition' => has_addition,
        'instances_lost' => lost.length,
        'subfields_lost' => subfield_losses + position_losses,
        'lost' => lost,
        'added' => added,
        'modified' => modified
      }
    end
  end
end
