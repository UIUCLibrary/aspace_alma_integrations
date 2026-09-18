module AlmaIntegrations
  # A word-level diff between two subfield values, so the side-by-side view can
  # highlight the words that actually changed instead of colouring a whole
  # paragraph because one date was corrected.
  #
  # This is deliberately a small local implementation rather than a gem. The
  # only thing needed here is a longest common subsequence over a short list of
  # tokens, and an ArchivesSpace plugin that carries its own gems has to get
  # them working under JRuby on every deployment. The MARC-aware comparison --
  # the part that is genuinely hard and worth borrowing -- already lives in
  # MarcDiff.
  module WordDiff

    # Above this, the quadratic table costs more than the highlighting is worth,
    # and the value is almost certainly a long note that was rewritten wholesale
    # rather than edited. The common prefix and suffix are removed first, so
    # this only bites on values that really are largely different.
    MAX_TABLE_CELLS = 250_000

    # Words and runs of whitespace are kept as separate tokens so the rebuilt
    # value is byte-for-byte the original.
    TOKEN_PATTERN = /\s+|\S+/.freeze

    module_function

    # Returns [left_segments, right_segments]. Each segment is
    # { 'text' => String, 'changed' => true|false }, and joining the texts of
    # either side reproduces that side's value exactly.
    def call(before, after)
      before = before.to_s
      after = after.to_s

      return [segments_for(before, false), segments_for(after, false)] if before == after

      left = before.scan(TOKEN_PATTERN)
      right = after.scan(TOKEN_PATTERN)

      head = common_prefix_length(left, right)
      tail = common_suffix_length(left, right, head)

      left_middle = left[head, left.length - head - tail] || []
      right_middle = right[head, right.length - head - tail] || []

      left_marks, right_marks =
        if left_middle.length * right_middle.length > MAX_TABLE_CELLS
          [Array.new(left_middle.length, true), Array.new(right_middle.length, true)]
        else
          mark_differences(left_middle, right_middle)
        end

      [
        build(left, head, tail, left_marks),
        build(right, head, tail, right_marks)
      ]
    end

    def segments_for(text, changed)
      text.empty? ? [] : [{ 'text' => text, 'changed' => changed }]
    end

    def common_prefix_length(left, right)
      limit = [left.length, right.length].min
      index = 0
      index += 1 while index < limit && left[index] == right[index]
      index
    end

    def common_suffix_length(left, right, head)
      limit = [left.length, right.length].min - head
      index = 0
      index += 1 while index < limit && left[left.length - 1 - index] == right[right.length - 1 - index]
      index
    end

    # Standard longest common subsequence. Tokens on the subsequence are
    # unchanged; everything else is marked.
    def mark_differences(left, right)
      lengths = lcs_table(left, right)

      left_marks = Array.new(left.length, true)
      right_marks = Array.new(right.length, true)

      row = 0
      column = 0
      while row < left.length && column < right.length
        if left[row] == right[column]
          left_marks[row] = false
          right_marks[column] = false
          row += 1
          column += 1
        elsif lengths[row + 1][column] >= lengths[row][column + 1]
          row += 1
        else
          column += 1
        end
      end

      [left_marks, right_marks]
    end

    def lcs_table(left, right)
      table = Array.new(left.length + 1) { Array.new(right.length + 1, 0) }

      (left.length - 1).downto(0) do |row|
        (right.length - 1).downto(0) do |column|
          table[row][column] = if left[row] == right[column]
                                 table[row + 1][column + 1] + 1
                               else
                                 [table[row + 1][column], table[row][column + 1]].max
                               end
        end
      end

      table
    end

    # Rebuilds a side from its tokens, collapsing neighbouring tokens that share
    # a verdict into one segment so the markup stays small.
    def build(tokens, head, tail, middle_marks)
      marks = Array.new(head, false) + middle_marks + Array.new(tail, false)

      segments = []
      tokens.each_with_index do |token, index|
        changed = marks[index] ? true : false

        if segments.empty? || segments.last['changed'] != changed
          segments << { 'text' => token.dup, 'changed' => changed }
        else
          segments.last['text'] << token
        end
      end

      segments
    end
  end
end
