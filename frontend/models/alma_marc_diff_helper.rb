# View helpers for the side-by-side MARC comparison.
#
# ArchivesSpace does not autoload a plugin's `frontend/helpers` directory -- only
# `frontend/controllers` and `frontend/models` are added to the Rails autoload
# paths -- so this module lives here and is registered with
# `ApplicationController.helper` in frontend/plugin_init.rb.
module AlmaMarcDiffHelper

  STATUS_CLASSES = {
    'unchanged' => 'alma-diff-same',
    'changed'   => 'alma-diff-changed',
    'lost'      => 'alma-diff-lost',
    'added'     => 'alma-diff-added',
    'ignored'   => 'alma-diff-ignored'
  }.freeze

  # Builds the alignment both columns are rendered from. Running it once for the
  # pair means a field can never be marked lost on one side without its
  # counterpart being marked on the other.
  #
  # The comparison is configured from AppConfig exactly as the audit job
  # configures it, so the highlighting cannot quietly disagree with the report
  # it was reached from.
  def alma_marc_alignment(alma_marc, aspace_marc)
    return nil if alma_marc.to_s.strip.empty? || aspace_marc.to_s.strip.empty?

    settings = AlmaIntegrations::Settings.from_app_config
    AlmaIntegrations::MarcDiff.new(settings).align(alma_marc, aspace_marc)
  rescue StandardError => e
    Rails.logger.warn("Alma integrations: could not compare the MARC records: #{e.message}")
    nil
  end

  # One field of one record. Returns a placeholder when this side has no
  # counterpart, so the two columns stay in step line for line.
  def alma_marc_field(row, side)
    field = row[side]

    if field.nil?
      return content_tag(:div, ''.html_safe,
                         :class => 'alma-diff-row alma-diff-absent',
                         :'aria-hidden' => 'true')
    end

    status = row['enrichment'] ? 'ignored' : row['status']
    parts = row["#{side}_parts"] || []

    body = if field['subfields'].nil?
             alma_marc_control_value(row, field)
           else
             alma_marc_indicators(row, field) + alma_marc_subfields(parts)
           end

    content_tag(:div,
                content_tag(:span, field['tag'], :class => 'alma-diff-tag') + body,
                :class => "alma-diff-row #{STATUS_CLASSES.fetch(status, 'alma-diff-same')}")
  end

  def alma_marc_indicators(row, field)
    # Blanks are shown as # so two blank indicators are visible rather than
    # looking like the indicators are missing.
    text = "#{field['ind1']}#{field['ind2']}".tr(' ', '#')
    css = row['indicators_changed'] ? 'alma-diff-indicators alma-diff-changed' : 'alma-diff-indicators'

    content_tag(:span, text, :class => css)
  end

  def alma_marc_subfields(parts)
    rendered = parts.map do |part|
      value = if part['status'] == 'changed' && part.key?('counterpart')
                alma_marc_word_diff(part['value'], part['counterpart'])
              else
                h(part['value'].to_s)
              end

      content_tag(:span,
                  content_tag(:span, "$#{part['code']}", :class => 'alma-diff-code') + ' '.html_safe + value,
                  :class => "alma-diff-subfield #{STATUS_CLASSES.fetch(part['status'], 'alma-diff-same')}")
    end

    content_tag(:span, safe_join(rendered, ' '.html_safe), :class => 'alma-diff-value')
  end

  # Only the words that differ are marked, so a corrected date inside a long
  # scope note does not light up the whole paragraph.
  def alma_marc_word_diff(value, counterpart)
    segments, = AlmaIntegrations::WordDiff.call(value.to_s, counterpart.to_s)

    safe_join(segments.map do |segment|
      if segment['changed']
        content_tag(:mark, segment['text'], :class => 'alma-diff-word')
      else
        h(segment['text'])
      end
    end)
  end

  # Control fields and the leader are fixed-length strings, so the differing
  # character positions are marked rather than the whole value. The MARC name
  # for the position is put in the title so hovering explains what changed.
  def alma_marc_control_value(row, field)
    value = field['value'].to_s
    runs = Array(row['positions'])

    return content_tag(:span, h(value), :class => 'alma-diff-value alma-diff-control') if runs.empty?

    marked = Array.new(value.length, false)
    runs.each do |run|
      (run['start'].to_i..run['end'].to_i).each { |index| marked[index] = true if index < value.length }
    end

    title = runs.map { |run| run['label'] }.compact.uniq.join(', ')

    pieces = []
    value.each_char.with_index do |character, index|
      if pieces.empty? || pieces.last[:marked] != marked[index]
        pieces << { :marked => marked[index], :text => character.dup }
      else
        pieces.last[:text] << character
      end
    end

    rendered = pieces.map do |piece|
      if piece[:marked]
        content_tag(:mark, piece[:text], :class => 'alma-diff-word', :title => (title.empty? ? nil : title))
      else
        h(piece[:text])
      end
    end

    content_tag(:span, safe_join(rendered), :class => 'alma-diff-value alma-diff-control')
  end

  def alma_marc_diff_counts(alignment)
    counts = (alignment || {})['counts'] || {}

    {
      :lost => counts['lost'].to_i,
      :changed => counts['changed'].to_i,
      :added => counts['added'].to_i,
      :unchanged => counts['unchanged'].to_i
    }
  end
end
