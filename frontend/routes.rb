ArchivesSpace::Application.routes.draw do
  [AppConfig[:frontend_proxy_prefix], AppConfig[:frontend_prefix]].uniq.each do |prefix|
    scope prefix do
      match('/plugins/alma_integrations' => 'alma_integrations#index', :via => [:get])
      match('/plugins/alma_integrations/search' => 'alma_integrations#search', :via => [:post])
      match('/plugins/alma_integrations/add_bibs' => 'alma_integrations#add_bibs', :via => [:post])
      match('/plugins/alma_integrations/add_holdings' => 'alma_integrations#add_holdings', :via => [:post])
      match('/plugins/alma_integrations/add_items' => 'alma_integrations#add_items', :via => [:post])

      # Audit reports. Audits run as background jobs, so this is where you come
      # back to read one rather than waiting on a page while it runs.
      match('/plugins/alma_audit_reports' => 'alma_audit_reports#index', :via => [:get])
      match('/plugins/alma_audit_reports/:id' => 'alma_audit_reports#show', :via => [:get])
    end
  end
end
