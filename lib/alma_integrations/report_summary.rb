require_relative 'settings'
require_relative 'marc_labels'

module AlmaIntegrations
  # Accumulates the headline numbers for the audit report as records stream past,
  # so a run of many thousands of records never needs to hold every diff in
  # memory at once.
  class ReportSummary

    # Tags that describe the record itself rather than its content, and that
    # therefore cannot sensibly be added to the preserve list.
    NON_PRESERVABLE_TAGS = [MarcLabels::LEADER, '001', '003', '005', '008'].freeze

    FIELD_COUNTERS = %w[
      records_in_alma
      records_in_outgoing
      records_with_loss
      records_with_full_loss
      records_with_partial_loss
      records_with_change
      records_with_addition
      instances_lost
      subfields_lost
    ].freeze

    def initialize(settings = nil)
      @settings = settings.is_a?(Settings) ? settings : Settings.new(settings || {})
      @ignored_tags = Array(@settings[:ignored_tags]).map(&:to_s)
      @preserved_tags = Array(@settings[:preserved_tags]).map(&:to_s)

      @fields = {}
      @records = {
        'total' => 0,
        'audited' => 0,
        'errored' => 0,
        'skipped' => 0,
        'network_zone_linked' => 0,
        'with_loss' => 0,
        'with_change' => 0,
        'with_addition' => 0,
        'identical' => 0
      }
      @error_kinds = Hash.new(0)
      @warnings = []
    end

    def record_submitted(count = 1)
      @records['total'] += count
    end

    def add_error(kind)
      @records['errored'] += 1
      @error_kinds[kind.to_s] += 1
    end

    def add_skipped(kind)
      @records['skipped'] += 1
      @error_kinds[kind.to_s] += 1
    end

    def add_warning(message)
      @warnings << message unless @warnings.include?(message)
    end

    # diff is the Hash returned by MarcDiff#diff.
    def add_record(diff, network_zone_linked: false)
      @records['audited'] += 1
      @records['network_zone_linked'] += 1 if network_zone_linked

      @records['with_loss'] += 1 if diff['has_loss']
      @records['with_change'] += 1 if diff['has_change']
      @records['with_addition'] += 1 if diff['has_addition']
      @records['identical'] += 1 unless diff['has_loss'] || diff['has_change'] || diff['has_addition']

      (diff['alma_tag_counts'] || {}).each_key do |tag|
        counters_for(tag)['records_in_alma'] += 1
      end

      (diff['outgoing_tag_counts'] || {}).each_key do |tag|
        counters_for(tag)['records_in_outgoing'] += 1
      end

      Array(diff['fields']).each do |entry|
        counters = counters_for(entry['tag'])

        if entry['has_loss']
          counters['records_with_loss'] += 1
          if entry['full_loss']
            counters['records_with_full_loss'] += 1
          else
            counters['records_with_partial_loss'] += 1
          end
        end

        counters['records_with_change'] += 1 if entry['has_change']
        counters['records_with_addition'] += 1 if entry['has_addition']
        counters['instances_lost'] += entry['instances_lost'].to_i
        counters['subfields_lost'] += entry['subfields_lost'].to_i
      end
    end

    def audited
      @records['audited']
    end

    def to_h
      {
        'records' => @records.dup,
        'errors_by_kind' => @error_kinds.dup,
        'fields' => field_rows,
        'excluded_from_summary' => excluded_from_summary,
        'recommended_preserve_tags' => recommended_preserve_tags,
        'warnings' => warnings
      }
    end

    # Control fields such as 001, 003 and 005 differ mechanically on every single
    # record, so counting them would drown out the fields a cataloguer actually
    # cares about. They are left out of the headline counts but still compared,
    # and the per-record detail is in the downloadable JSON. The interface says so
    # explicitly rather than quietly hiding them.
    def excluded_from_summary
      @ignored_tags.map do |tag|
        {
          'tag' => tag,
          'label' => MarcLabels.tag_label(tag),
          'reason' => 'Differs mechanically on every record; see the per-record detail in the JSON report.'
        }
      end
    end

    private

    def counters_for(tag)
      @fields[tag.to_s] ||= FIELD_COUNTERS.each_with_object({}) { |name, out| out[name] = 0 }
    end

    def field_rows
      total = [audited, 1].max

      rows = @fields.map do |tag, counters|
        counters.merge(
          'tag' => tag,
          'label' => MarcLabels.tag_label(tag),
          'ignored' => @ignored_tags.include?(tag),
          'preserved' => @preserved_tags.include?(tag),
          'loss_ratio' => ratio(counters['records_with_loss'], total),
          'change_ratio' => ratio(counters['records_with_change'], total)
        )
      end

      # Most damaging first, so the summary leads with what matters.
      rows.sort_by do |row|
        [-row['records_with_loss'], -row['records_with_change'], row['tag']]
      end
    end

    def ratio(count, total)
      return 0.0 if total.zero?

      (count.to_f / total).round(4)
    end

    # The practical payoff of the audit: which tags lose data often enough that
    # they belong in AppConfig[:alma_marc_fields_to_preserve].
    def recommended_preserve_tags
      threshold = @settings[:recommend_threshold].to_f
      total = audited
      return [] if total.zero?

      @fields.reject { |tag, _| NON_PRESERVABLE_TAGS.include?(tag) }
             .reject { |tag, _| @ignored_tags.include?(tag) }
             .reject { |tag, _| @preserved_tags.include?(tag) }
             .select { |_, counters| counters['records_with_loss'].to_f / total >= threshold }
             .map do |tag, counters|
               {
                 'tag' => tag,
                 'label' => MarcLabels.tag_label(tag),
                 'records_with_loss' => counters['records_with_loss'],
                 'loss_ratio' => ratio(counters['records_with_loss'], total)
               }
             end
             .sort_by { |row| [-row['records_with_loss'], row['tag']] }
    end

    def warnings
      warnings = @warnings.dup

      if @records['network_zone_linked'] > 0
        warnings << "#{@records['network_zone_linked']} of the audited records are linked to a Network Zone " \
                    'record. Alma replaces only the local fields of those records on update, so the losses ' \
                    'reported for network-managed fields would not actually occur. They are excluded from bulk ' \
                    'updates unless the Network Zone option is selected.'
      end

      warnings
    end
  end
end
