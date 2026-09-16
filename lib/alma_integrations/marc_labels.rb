module AlmaIntegrations
  # Labels for MARC tags and for the named character positions of the leader and
  # the 008 control field, so the audit report reads like cataloguing rather than
  # like a byte diff.
  module MarcLabels

    TAGS = {
      '010' => 'Library of Congress Control Number',
      '020' => 'ISBN',
      '022' => 'ISSN',
      '024' => 'Other Standard Identifier',
      '035' => 'System Control Number',
      '040' => 'Cataloging Source',
      '041' => 'Language Code',
      '043' => 'Geographic Area Code',
      '049' => 'Local Holdings',
      '050' => 'Library of Congress Call Number',
      '082' => 'Dewey Decimal Call Number',
      '090' => 'Local Call Number',
      '099' => 'Local Free-Text Call Number',
      '100' => 'Main Entry - Personal Name',
      '110' => 'Main Entry - Corporate Name',
      '111' => 'Main Entry - Meeting Name',
      '130' => 'Main Entry - Uniform Title',
      '210' => 'Abbreviated Title',
      '245' => 'Title Statement',
      '246' => 'Varying Form of Title',
      '250' => 'Edition Statement',
      '254' => 'Musical Presentation Statement',
      '255' => 'Cartographic Mathematical Data',
      '260' => 'Publication, Distribution (Imprint)',
      '264' => 'Production, Publication, Distribution',
      '300' => 'Physical Description',
      '336' => 'Content Type',
      '337' => 'Media Type',
      '338' => 'Carrier Type',
      '340' => 'Physical Medium',
      '351' => 'Organization and Arrangement of Materials',
      '490' => 'Series Statement',
      '500' => 'General Note',
      '501' => 'With Note',
      '502' => 'Dissertation Note',
      '504' => 'Bibliography Note',
      '505' => 'Formatted Contents Note',
      '506' => 'Restrictions on Access Note',
      '508' => 'Creation/Production Credits Note',
      '510' => 'Citation/References Note',
      '511' => 'Participant or Performer Note',
      '520' => 'Summary, Etc.',
      '524' => 'Preferred Citation Note',
      '530' => 'Additional Physical Form Available Note',
      '533' => 'Reproduction Note',
      '534' => 'Original Version Note',
      '535' => 'Location of Originals/Duplicates Note',
      '540' => 'Terms Governing Use and Reproduction Note',
      '541' => 'Immediate Source of Acquisition Note',
      '544' => 'Location of Other Archival Materials Note',
      '545' => 'Biographical or Historical Data',
      '546' => 'Language Note',
      '555' => 'Cumulative Index/Finding Aids Note',
      '561' => 'Ownership and Custodial History',
      '562' => 'Copy and Version Identification Note',
      '563' => 'Binding Information',
      '583' => 'Action Note',
      '584' => 'Accumulation and Frequency of Use Note',
      '590' => 'Local Note',
      '600' => 'Subject Added Entry - Personal Name',
      '610' => 'Subject Added Entry - Corporate Name',
      '611' => 'Subject Added Entry - Meeting Name',
      '630' => 'Subject Added Entry - Uniform Title',
      '648' => 'Subject Added Entry - Chronological Term',
      '650' => 'Subject Added Entry - Topical Term',
      '651' => 'Subject Added Entry - Geographic Name',
      '655' => 'Index Term - Genre/Form',
      '656' => 'Index Term - Occupation',
      '657' => 'Index Term - Function',
      '690' => 'Local Subject Added Entry',
      '700' => 'Added Entry - Personal Name',
      '710' => 'Added Entry - Corporate Name',
      '711' => 'Added Entry - Meeting Name',
      '730' => 'Added Entry - Uniform Title',
      '740' => 'Added Entry - Uncontrolled Title',
      '752' => 'Added Entry - Hierarchical Place Name',
      '773' => 'Host Item Entry',
      '787' => 'Other Relationship Entry',
      '830' => 'Series Added Entry - Uniform Title',
      '852' => 'Location',
      '856' => 'Electronic Location and Access',
      '883' => 'Machine-Generated Metadata Provenance',
      '901' => 'Local Data',
      '902' => 'Local Data',
      '909' => 'Local Data',
      '910' => 'Local Data',
      '940' => 'Local Data',
      '955' => 'Local Data',
      '994' => 'Local Data (OCLC)',
      '999' => 'Local Data',
      '001' => 'Control Number',
      '003' => 'Control Number Identifier',
      '005' => 'Date and Time of Latest Transaction',
      '006' => 'Additional Material Characteristics',
      '007' => 'Physical Description Fixed Field',
      '008' => 'Fixed-Length Data Elements'
    }.freeze

    LEADER = 'LDR'.freeze

    # Leader positions that are recalculated by whichever system writes the
    # record and therefore carry no cataloguing intent.
    LEADER_MECHANICAL_POSITIONS = ((0..4).to_a + (12..16).to_a + (20..23).to_a).freeze

    LEADER_POSITIONS = [
      [5,  5,  'Record status'],
      [6,  6,  'Type of record'],
      [7,  7,  'Bibliographic level'],
      [8,  8,  'Type of control'],
      [9,  9,  'Character coding scheme'],
      [10, 10, 'Indicator count'],
      [11, 11, 'Subfield code count'],
      [17, 17, 'Encoding level'],
      [18, 18, 'Descriptive cataloging form'],
      [19, 19, 'Multipart resource record level']
    ].freeze

    # Positions of the 008 for books/mixed materials. The 18-34 block is format
    # dependent; archival material (Type of record "p") is the common case here.
    CONTROL_008_POSITIONS = [
      [0,  5,  'Date entered on file'],
      [6,  6,  'Type of date/Publication status'],
      [7,  10, 'Date 1'],
      [11, 14, 'Date 2'],
      [15, 17, 'Place of publication'],
      [18, 34, 'Material specific coded elements'],
      [35, 37, 'Language'],
      [38, 38, 'Modified record'],
      [39, 39, 'Cataloging source']
    ].freeze

    module_function

    def tag_label(tag)
      TAGS[tag.to_s]
    end

    def tag_display(tag)
      label = tag_label(tag)
      label.nil? ? tag.to_s : "#{tag} - #{label}"
    end

    def mechanical_positions(tag)
      tag.to_s == LEADER ? LEADER_MECHANICAL_POSITIONS : []
    end

    def position_label(tag, start_pos, end_pos)
      ranges = case tag.to_s
               when LEADER then LEADER_POSITIONS
               when '008' then CONTROL_008_POSITIONS
               else return nil
               end

      matches = ranges.select { |from, to, _| from <= end_pos && to >= start_pos }
      return nil if matches.empty?

      matches.map { |_, _, label| label }.uniq.join(', ')
    end
  end
end
