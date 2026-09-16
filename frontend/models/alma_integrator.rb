require 'net/http'
require 'nokogiri'
require 'advanced_query_builder'

class AlmaIntegrator

  def initialize(baseurl, key)
    @baseurl = baseurl
    @key = key
  end

  def get_archivesspace_bib(ref)
    aspace = {}
    uri = URI("#{JSONModel::HTTP.backend_url}#{ref.gsub(/(\d+)$/,'marc21/\1.xml')}")
    response = AlmaRequester.new.get(uri)
    if response.is_a?(Net::HTTPSuccess)
      xml = Nokogiri::XML(response.body,&:noblanks)
      aspace['content'] = xml.at_css('record')
    else
      aspace['error'] = JSON.parse(response.body)['error']
    end

    return aspace
  end

  def get_alma_bib(mms)
    alma = {}

    if mms.nil?
      alma['error'] = I18n.t("plugins.alma_integrations.errors.no_mms")
    else
      uri = URI("#{@baseurl}/#{mms}")
      uri.query = URI.encode_www_form({:apikey => @key})
      response = AlmaRequester.new.get(uri, :use_ssl => true)

      if response.is_a?(Net::HTTPSuccess)
        xml = Nokogiri::XML(response.body,&:noblanks)
        alma['content'] = xml.at_css('record')
        # A 200 with no record in it is not a success from our point of view.
        alma['error'] = I18n.t("plugins.alma_integrations.errors.no_alma_record") if alma['content'].nil?
      else
        # Alma reports errors as XML, as JSON, and occasionally as an HTML error
        # page from something in front of it. The previous implementation
        # assumed XML with errorCode and errorMessage elements and raised
        # NoMethodError on anything else, turning a transient gateway error into
        # a crash.
        alma['error'] = AlmaIntegrations::ErrorParser.describe(response.body, response.code)
      end
    end

    alma
  end

  # Prepares the ASpace-generated MARC record for overlay into Alma by preserving
  # specific fields from the existing Alma record that ArchivesSpace does not manage.
  #
  # The MARC 008 control field positions 00-05 encode the "Date Entered on File" —
  # the six-digit date (YYMMDD) when the record was first created in the system.
  # ArchivesSpace regenerates this date each time it produces MARC output, so without
  # intervention, pushing an ASpace record to Alma would silently overwrite the original
  # Alma creation date with today's date. This method always preserves Alma's 008/00-05
  # in the outgoing record.
  #
  # Additionally, any MARC field tags listed in AppConfig[:alma_marc_fields_to_preserve]
  # (e.g. ['035'] to retain OCLC system control numbers) are carried over wholesale from
  # the Alma record into the ASpace record, replacing any instances of those fields that
  # ASpace may have generated. This allows institutions to protect locally significant
  # Alma-managed fields from being overwritten on push.
  #
  # The work itself is done by AlmaIntegrations::MarcPreserver, which the bulk
  # audit and bulk update jobs also use. Sharing one implementation is what lets
  # the audit report claim to describe what a push would really do -- two copies
  # of this logic would eventually disagree, and the report would start lying.
  def preserve_alma_marc_fields(aspace, alma)
    @preserve_result = marc_preserver.apply(aspace['content'], alma['content'])
    @preserve_result.to_xml(:indent => 2)
  end

  # Warnings raised while preserving fields on the most recent call, e.g. a
  # record with no 008 to carry the creation date over from.
  def preserve_warnings
    @preserve_result.nil? ? [] : @preserve_result.warnings
  end

  def marc_preserver
    @marc_preserver ||= AlmaIntegrations::MarcPreserver.new(AlmaIntegrations::Settings.from_app_config)
  end

  def search_bibs(ref, mms)
    results = {'mms' => mms}

    # first, try to get the ArchivesSpace MARC record
    # next, try to get the Alma MARC record
    # last, compare them to see if any changes need to be made before overlay
    # (e.g. bringing over Alma's 008/0-5 for date on file)

    aspace = get_archivesspace_bib(ref)
    if aspace.has_key?('error')
      results['aspace'] = {'error' => aspace['error']}
      results['alma'] = {'error' => I18n.t("plugins.alma_integrations.errors.no_marc")}
    else
      results['aspace'] = {'success' => ref}
      alma = get_alma_bib(mms)
      if alma.has_key?('error')
        results['alma'] = {'error' => alma['error']}
        results['alma_marc'] = nil
        results['marc'] = aspace['content'].to_xml(indent: 2)
        results['aspace_marc'] = results['marc']
      else
        results['alma'] = {'success' => mms}
        results['alma_marc'] = alma['content'].to_xml(indent: 2)
        results['marc'] = preserve_alma_marc_fields(aspace, alma)
        results['aspace_marc'] = results['marc']
        results['preserve_warnings'] = preserve_warnings
      end
    end

    results
  end

  def search_holdings(mms)
    results = { 'holdings' => [], 'count' => 0 }

    # Returning the empty results hash rather than nil: callers index into this
    # (e.g. results['holdings']), so handing back nil turned "this record has no
    # MMS ID" into a NoMethodError further up the page.
    return results if mms.nil?

    uri = URI("#{@baseurl}/#{mms}/holdings")
    uri.query = URI.encode_www_form({:apikey => @key, :format => 'json'})
    response = AlmaRequester.new.get(uri, :use_ssl => true)

    if response.is_a?(Net::HTTPSuccess)
			obj = JSON.parse(response.body)
			results['count'] = obj['total_record_count']
			if results['count'] > 0
				holdings = obj['holding']
				holdings.each do |holding|
					h = {
						'id' => holding['holding_id'],
						'code' => holding['location']['value'],
						'name' => holding['location']['desc']
					}

					results['holdings'].push(h)
				end
			end
		end

		results
  end

  def get_aspace_item_data(barcode)
    item_data = {}

		aq = AdvancedQueryBuilder.new
		aq.and('barcode_u_sstr', barcode)
		url = JSONModel(:top_container).uri_for("search")
		obj = JSONModel::HTTP::get_json(url, {'filter' => aq.build.to_json})

    item = obj['response']['docs'].first
    return item_data if item.nil?

    unless item['container_profile_display_string_u_sstr'].nil?
      item_data['profile'] = item['container_profile_display_string_u_sstr'].first
        .partition('[')
        .first
        .rstrip
    end
    item_data['top_container'] = item['uri'] unless item['uri'].nil?

    return item_data
	end

  def search_items(mms,page)
    results = { 'page' => page, 'offset' => (page - 1) * 10, 'items' => [] }

		uri = URI("#{@baseurl}/#{mms}/holdings/ALL/items")
		uri.query = URI.encode_www_form({:apikey => @key, :format => 'json', :offset => results['offset']})
		response = AlmaRequester.new.get(uri, :use_ssl => true)

		if response.is_a?(Net::HTTPSuccess)
			obj = JSON.parse(response.body)
			results['count'] = obj['total_record_count']
      # round(-1)/10 rounds to the nearest ten before dividing, so 104 items
      # produced 10 pages (losing the last 4) and 105 produced 11 (inventing an
      # empty one). Ceiling division is what paging actually wants.
      results['last_page'] = (results['count'].to_i / 10.0).ceil
			if results['count'] > 0
				items = obj['item']
				items.each do |item|
					item_data = item['item_data']
					as_item_data = get_aspace_item_data(item_data['barcode'])
					i = {
						'pid' => item_data['pid'],
            'barcode' => item_data['barcode'],
            'description' => item_data['description'],
            'location' => item_data['location']['value'],
						'alma_profile' => item_data['internal_note_2'],
						'as_profile' => as_item_data['profile'],
						'top_container' => as_item_data['top_container']
					}

					results['items'].push(i)
				end
			end
		end

		results
	end

  def post_bib(mms, data)
    if mms.nil?
      uri = URI(@baseurl)
      uri.query = URI.encode_www_form({:apikey => @key})
      response = AlmaRequester.new.post(uri, data, :use_ssl => true)
    else
      uri = URI("#{@baseurl}/#{mms}")
      uri.query = URI.encode_www_form({:apikey => @key})
      response = AlmaRequester.new.put(uri, data, :use_ssl => true)
    end

    response
  end

  def post_holding(mms, data)
    uri = URI("#{@baseurl}/#{mms}/holdings")
    uri.query = URI.encode_www_form({:apikey => @key})
    response = AlmaRequester.new.post(uri, data, :use_ssl => true)

    response
  end

  def post_item(mms, holding_id, data)
    uri = URI("#{@baseurl}/#{mms}/holdings/#{holding_id}/items")
    uri.query = URI.encode_www_form({:apikey => @key})
    response = AlmaRequester.new.post(uri, data, :use_ssl => true)

    response
  end

  def get_alma_item(mms, holding_id, pid)
    uri = URI("#{@baseurl}/#{mms}/holdings/#{holding_id}/items/#{pid}")
    uri.query = URI.encode_www_form({:apikey => @key, :format => 'xml'})
    response = AlmaRequester.new.get(uri, :use_ssl => true)
    return nil unless response.is_a?(Net::HTTPSuccess)

    Nokogiri::XML(response.body)
  end

  def update_item(mms, holding_id, pid, data)
    uri = URI("#{@baseurl}/#{mms}/holdings/#{holding_id}/items/#{pid}")
    uri.query = URI.encode_www_form({:apikey => @key})
    response = AlmaRequester.new.put(uri, data, :use_ssl => true)

    response
  end

  # Returns a hash keyed by barcode for every item currently held in Alma for
  # the given BIB, paging through all results. Used to detect duplicates before
  # creating or overwriting item records.
  def get_all_items_index(mms)
    index = {}
    return index if mms.nil?

    offset = 0
    loop do
      uri = URI("#{@baseurl}/#{mms}/holdings/ALL/items")
      uri.query = URI.encode_www_form({:apikey => @key, :format => 'json', :offset => offset, :limit => 50})
      response = AlmaRequester.new.get(uri, :use_ssl => true)
      break unless response.is_a?(Net::HTTPSuccess)

      obj   = JSON.parse(response.body)
      total = obj['total_record_count'].to_i
      items = obj['item'] || []
      break if items.empty?

      items.each do |item|
        item_data    = item['item_data']
        holding_data = item['holding_data']
        barcode      = item_data['barcode']
        next if barcode.nil? || barcode.empty?

        index[barcode] = {
          'pid'        => item_data['pid'],
          'holding_id' => holding_data['holding_id']
        }
      end

      offset += items.length
      break if offset >= total
    end

    index
  end

  def get_top_container(ref)
    obj = JSONModel::HTTP::get_json(ref, {'resolve[]' => 'container_profile'})
    return nil if obj.nil?

    type      = obj['type']
    indicator = obj['indicator']
    barcode   = obj['barcode']
    profile   = unless obj['container_profile'].nil?
      obj['container_profile']['_resolved']&.dig('name')
    end

    {
      'ref'         => ref,
      'type'        => type,
      'indicator'   => indicator,
      'barcode'     => barcode,
      'profile'     => profile,
      'description' => [type&.capitalize, indicator].compact.join(' ')
    }
  end

  def get_resource_top_containers(resource_ref)
    containers = []

    aq = AdvancedQueryBuilder.new
    aq.and('collection_uri_u_sstr', resource_ref)
    url = JSONModel(:top_container).uri_for("search")

    offset = 0
    loop do
      obj = JSONModel::HTTP::get_json(url, {
        'filter' => aq.build.to_json,
        'offset' => offset,
        'limit'  => 50
      })

      docs = obj['response']['docs']
      break if docs.nil? || docs.empty?

      docs.each do |doc|
        type      = doc['type_u_sstr']&.first
        indicator = doc['indicator_u_sstr']&.first
        barcode   = doc['barcode_u_sstr']&.first
        profile   = unless doc['container_profile_display_string_u_sstr'].nil?
          doc['container_profile_display_string_u_sstr'].first
            .partition('[')
            .first
            .rstrip
        end

        containers << {
          'ref'         => doc['uri'],
          'type'        => type,
          'indicator'   => indicator,
          'barcode'     => barcode,
          'profile'     => profile,
          'description' => doc['display_string']
        }
      end

      offset += docs.length
      break if containers.length >= obj['response']['numFound'].to_i
    end

    containers.sort_by { |c| [c['type'].to_s, c['indicator'].to_s.scan(/\d+/).first&.to_i || 0, c['indicator'].to_s] }
  end
end
