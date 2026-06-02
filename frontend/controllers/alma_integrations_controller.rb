require 'advanced_query_builder'

class AlmaIntegrationsController < ApplicationController

  set_access_control "view_repository" => [:index, :search, :add_bibs, :add_holdings, :add_items]

  def index
  end

  def search
    if params['resource'].nil? && params['ref'].nil?
    	flash[:error] = "Error: No resource selected"
    	redirect_to :action => :index
    end

    params['ref'] = params['resource']['ref'] if params['ref'].nil?
    @results = do_search(params)
    @holdings = AppConfig[:alma_holdings] if params['record_type'] == 'holdings'
    if params['record_type'] == 'items'
      @holdings = integrator.search_holdings(@results['mms'])
      @aspace_containers = integrator.get_resource_top_containers(params['ref'])
      @alma_items_index = integrator.get_all_items_index(@results['mms'])
    end
  end

  def add_bibs
    post_bibs(params)
  end

  # debugging adding holdings
  def add_holdings
    post_holdings(params)
  end

  def add_items
    post_items(params)
  end

  private

  def integrator
  	AlmaIntegrator.new(AppConfig[:alma_api_url], AppConfig[:alma_apikey])
  end

  # set this to your user-defined MMS ID field
  def mms_field
    'string_2'
  end

  def do_search(params)
  	ref = params['ref']
  	page = params['page'].nil? ? 1 : params['page'].to_i
  	json = JSONModel::HTTP::get_json(ref)

  	results = {
  		'title' => json['title'],
  		'id' => json['id_0'],
  		'ref' => ref,
  		'record_type' => params['record_type'],
  	}

  	if json['user_defined'].nil? or json['user_defined'][mms_field].nil?
  		results['mms'] = nil
  	else
  		results['mms'] = json['user_defined'][mms_field]
  	end

  	results['results'] = case params['record_type']
  	when "bibs"
  		integrator.search_bibs(ref, results['mms'])
  	when "holdings"
  		integrator.search_holdings(results['mms'])
  	when "items"
  		integrator.search_items(results['mms'], page)
  	end

  	results
  end

  def update_resource(ref, mms)
  	obj = JSONModel::HTTP.get_json(ref)
  	if obj['user_defined'].nil?
  		obj['user_defined'] = { mms_field => mms }
  	else
  		obj['user_defined'][mms_field] = mms
  	end

  	uri = URI("#{JSONModel::HTTP.backend_url}#{ref}")
  	response = JSONModel::HTTP.post_json(uri, obj.to_json)
  end

  def post_bibs(params)
  	data = RecordBuilder.new.build_bib(params['marc'], params['mms'])
  	response = integrator.post_bib(params['mms'], data)

  	if response.is_a?(Net::HTTPSuccess)
  		if params['mms'].nil?
  			doc = Nokogiri::XML(response.body)
  			mms = doc.at_css('mms_id').text
  			flash[:success] = "BIB created. MMS ID: #{mms}"
  			update_resource(params['ref'], mms)
  		else
  			flash[:success] = "BIB updated. MMS ID: #{params['mms']}"
  		end
  	else
  		flash[:error] = "Error: #{response.body}"
  	end

  	redirect_to :action => :index
  end

  def post_items(params)
    mms              = params['mms']
    holding_id       = params['holding_id']
    refs             = Array(params['container_refs'])
    duplicate_action = params['duplicate_action'] || 'overwrite'
    existing_items   = JSON.parse(params['existing_items'] || '{}')

    if mms.nil? || holding_id.nil? || refs.empty?
      flash[:error] = I18n.t("plugins.alma_integrations.errors.add_items_missing_params")
      redirect_to :action => :index
      return
    end

    successes = 0
    skipped   = 0
    errors    = []

    refs.each do |ref|
      container = integrator.get_top_container(ref)
      next if container.nil?

      barcode  = container['barcode']
      existing = barcode.present? ? existing_items[barcode] : nil

      if existing && duplicate_action == 'skip'
        skipped += 1
        next
      end

      # For overwrite, keep the item in its current holding; for new items,
      # use the holding_id selected in the form.
      target_holding_id = existing ? existing['holding_id'] : holding_id
      data = RecordBuilder.new.build_item(
        target_holding_id,
        barcode,
        container['description'],
        container['profile']
      )

      response = if existing
        integrator.update_item(mms, existing['holding_id'], existing['pid'], data)
      else
        integrator.post_item(mms, holding_id, data)
      end

      if response.is_a?(Net::HTTPSuccess)
        successes += 1
      else
        error_msg = begin
          doc = Nokogiri::XML(response.body)
          error_node = doc.at_css('errorMessage') || doc.at_css('errorCode')
          error_node ? error_node.text : response.body
        rescue StandardError
          response.body
        end
        errors << "#{container['description']}: #{error_msg}"
      end
    end

    messages = []
    messages << I18n.t("plugins.alma_integrations.success.items_added", :count => successes) if successes > 0
    messages << I18n.t("plugins.alma_integrations.success.items_skipped", :count => skipped) if skipped > 0

    if errors.empty?
      flash[:success] = messages.join(' ') unless messages.empty?
    else
      flash[:success] = messages.join(' ') unless messages.empty?
      flash[:error] = errors.join('; ')
    end

    redirect_to :action => :index
  end

  def post_holdings(params)
  	data = RecordBuilder.new.build_holding(params['code'], params['id'])
  	response = integrator.post_holding(params['mms'], data)

    if response.is_a?(Net::HTTPSuccess)
  		doc = Nokogiri::XML(response.body)
  		flash[:success] = "Holdings created. Holding ID: #{doc.at_css('holding_id').text}"
  	else
  		flash[:error] = "Error: #{response.body}"
  	end

  	redirect_to :action => :index
  end
end
