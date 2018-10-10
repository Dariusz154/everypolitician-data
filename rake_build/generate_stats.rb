# frozen_string_literal: true

#-----------------------------------------------------------------------
# Update the `stats.json` file for a Legislature
#-----------------------------------------------------------------------

require 'date' # To give us DateTime.now
require 'octokit'

STATSFILE = Pathname.new('unstable/stats.json')

namespace :stats do
  def local_git_lastmod(file)
    Date.parse `git log -1 --format="%ai" -- #{file}`.split.first
  end

  def octokit
    @octokit ||= Octokit::Client.new
  end

  def datapath
    @datapath ||= Pathname.pwd.relative_path_from(PROJECT.realpath)
  end

  def github_lastmod(file)
    lc = octokit.commits('everypolitician/everypolitician-data', path: datapath + file).first
    lc.commit.author.date.to_date
  end

  def lastmod(source)
    path = Pathname('sources') + source[:file]
    lm = ENV['EP_FULL_GIT'] ? local_git_lastmod(path) : github_lastmod(path)

    if source.key? :create
      elapsed = (DateTime.now - lm).to_i
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
