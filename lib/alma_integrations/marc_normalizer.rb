module AlmaIntegrations
  # Normalises subfield values before comparison.
  #
  # The raw values are always retained in the report; normalisation only affects
  # whether two values are considered equal, so that an audit of a thousand
  # records is not dominated by trailing ISBD punctuation.
  class MarcNormalizer

    # Trailing ISBD punctuation that cataloguing practice adds or drops without
    # changing the meaning of the data.
    TRAILING_PUNCTUATION = /[\s.,;:\/=+-]+\z/.freeze

    def initialize(whitespace: true, punctuation: true, casing: false)
      @whitespace = whitespace
      @punctuation = punctuation
      @casing = casing
    end

    def call(value)
      normalized = value.to_s

      if @whitespace
        normalized = normalized.gsub(/\s+/, ' ').strip
      end

      if @punctuation
        stripped = normalized.sub(TRAILING_PUNCTUATION, '')
        # Never normalise a value out of existence: "..." should not become "".
        normalized = stripped unless stripped.empty?
      end

      normalized = normalized.downcase if @casing

      normalized
    end

    alias_method :value, :call
  end
end
