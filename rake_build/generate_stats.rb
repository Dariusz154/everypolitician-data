# frozen_string_literal: true

#-----------------------------------------------------------------------
# Update the `stats.json` file for a Legislature
#-----------------------------------------------------------------------

require 'date' # To give us DateTime.now

STATSFILE = Pathname.new('unstable/stats.json')

namespace :stats do
  def lastmod(source)
    path = Pathname('sources') + source[:file]
    lm = `git log -1 --format="%ai" -- #{path}`.split.first
    if source.key? :create
      elapsed = (DateTime.now - Date.parse(lm)).to_i
      warn "  ☢  #{source[:file]} has not been updated for #{elapsed} days" if elapsed > 90
    end
    lm
  end

  task :regenerate do
    stats = StatsFile.new(popolo: ep_popolo, position_file: POSITION_CSV).stats
    stats[:sources] = json_load(@INSTRUCTIONS_FILE)[:sources].map do |src|
      {
        file:    src[:file],
        type:    src[:type],
        scraper: src.dig(:create, :scraper),
        lastmod: lastmod(src),
      }
    end
    STATSFILE.dirname.mkpath
    STATSFILE.write(JSON.pretty_generate(stats))
  end
end
