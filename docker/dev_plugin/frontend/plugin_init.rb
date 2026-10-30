# Show real exceptions in the browser, for local development only.
#
# ArchivesSpace runs Rails in production mode and there is no supported way to
# change that: `rails.env` is baked into WEB-INF/web.xml inside frontend.war, so
# switching to the development environment would mean rewriting the war on every
# start. In production mode a 500 renders a generic apology page and the real
# exception only reaches the log, which is why a broken view looks like "Sorry,
# something went wrong" and nothing else.
#
# The obvious fix -- setting `config.consider_all_requests_local = true` -- is
# explicitly warned against in ArchivesSpace's own config/environments/production.rb:
# under Rails 5.0.1 it caused compiled partials to accumulate until the process
# ran out of memory. That warning is no longer accurate for the Rails this
# ArchivesSpace ships (actionview 6.1.6 has no per_request_digest_cache
# initializer at all, and template caching now follows cache_classes), but there
# is no need to rely on that analysis, because Rails offers a narrower switch.
#
# ActionController::Rescue#show_detailed_exceptions? exists for exactly this
# purpose. Its own documentation says "Override this method if you want to
# customize when detailed exceptions must be shown. This method is only called
# when consider_all_requests_local is false." Overriding it turns on the debug
# error page and nothing else: no change to template caching, so none of the
# behaviour behind the ArchivesSpace warning is involved.
#
# This plugin deliberately lives under docker/ rather than in the plugin proper,
# and is mounted only by the local docker-compose stack. Rendering stack traces
# to the browser leaks source paths and application internals, so this must
# never reach a production ArchivesSpace. Keeping it physically outside the
# plugin means it cannot be switched on by accident there.
#
# Set ASPACE_DEBUG_EXCEPTIONS=false in docker/.env to turn it off.

if ENV.fetch('ASPACE_DEBUG_EXCEPTIONS', 'true').to_s.downcase == 'true'

  # plugin_init.rb is evaluated from config/application.rb, long before Rails
  # has built a logger or autoloaded any controller, so Rails.logger is nil
  # here and touching ApplicationController directly would force an autoload
  # in the middle of initialization. Announce on stderr, which the container
  # log captures, and hang the override off the standard load hook so it runs
  # once ActionController::Base actually exists.
  $stderr.puts(
    'alma_dev_errors: detailed exception pages are ON. Local development ' \
    'only - this renders stack traces to the browser. Set ' \
    'ASPACE_DEBUG_EXCEPTIONS=false to disable.'
  )

  ActiveSupport.on_load(:action_controller) do
    # Defined on ActionController::Base, so every ArchivesSpace controller
    # inherits it, and it takes precedence over the default that
    # ActionController::Rescue mixes in.
    #
    # ArchivesSpace rescues four specific exceptions of its own (SessionGone,
    # SessionExpired, RecordNotFound, AccessDeniedException) and lets
    # everything else through to Rails, so this is enough for the errors worth
    # debugging -- a NoMethodError in a view, a missing partial, a bad
    # JSONModel call -- to render with their backtrace and source extract.
    def show_detailed_exceptions?
      true
    end
  end

end

# Stub Alma API responses from fixture files when ALMA_STUB_DIR is set. See
# alma_stub.rb for why, and for how to point it at a fixture directory.
require_relative 'alma_stub'
