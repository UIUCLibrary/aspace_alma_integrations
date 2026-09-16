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

    private

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
      unchanged, alma_left, outgoing_left = match_identical(alma_fields, outgoing_fields)
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
                  unchanged,
                  alma_left.map(&:to_h),
                  outgoing_left.map(&:to_h),
                  modified)
    end

    # Step one: take out every field that survives byte-for-byte (after
    # normalisation), treating repeats as a multiset.
    def match_identical(alma_fields, outgoing_fields)
      available = {}
      outgoing_fields.each_with_index do |field, index|
        (available[field_key(field)] ||= []) << index
      end

      matched_outgoing = {}
      alma_left = []
      unchanged = 0

      alma_fields.each do |field|
        key = field_key(field)
        index = available[key] && available[key].shift

        if index.nil?
          alma_left << field
        else
          matched_outgoing[index] = true
          unchanged += 1
        end
      end

      outgoing_left = outgoing_fields.each_with_index.reject { |_, index| matched_outgoing[index] }.map(&:first)

      [unchanged, alma_left, outgoing_left]
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

    def diff_subfields(alma_field, outgoing_field)
      alma_parts = normalized_subfields(alma_field)
      outgoing_parts = normalized_subfields(outgoing_field)

      available = {}
      outgoing_parts.each_with_index { |part, index| (available[part] ||= []) << index }

      matched_outgoing = {}
      alma_left = []

      alma_parts.each_with_index do |part, index|
        match = available[part] && available[part].shift
        if match.nil?
          alma_left << index
        else
          matched_outgoing[match] = true
        end
      end

      outgoing_left = (0...outgoing_parts.length).reject { |index| matched_outgoing[index] }

      changed = []
      lost = []
      added = []

      # Within a field, a leftover on each side sharing a subfield code is a
      # changed value; anything still unpaired is a genuine loss or addition.
      outgoing_by_code = outgoing_left.group_by { |index| outgoing_parts[index].first }

      alma_left.each do |a_index|
        code = alma_parts[a_index].first
        b_index = outgoing_by_code[code] && outgoing_by_code[code].shift

        if b_index.nil?
          lost << subfield_hash(alma_field, a_index)
        else
          changed << {
            'code' => code,
            'alma' => alma_field.subfields[a_index].last,
            'outgoing' => outgoing_field.subfields[b_index].last
          }
        end
      end

      outgoing_by_code.each_value do |indexes|
        indexes.each { |b_index| added << subfield_hash(outgoing_field, b_index) }
      end

      {
        'lost' => lost,
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
