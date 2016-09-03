require_relative '../lib/position_filterer'
require 'everypolitician/popolo'
require 'json5'

desc 'Build the term-table CSVs'
task csvs: ['term_csvs:term_tables', 'term_csvs:name_list', 'term_csvs:positions', 'term_csvs:reports']

CLEAN.include('term-*.csv', 'names.csv')

namespace :term_csvs do
  def tidy_facebook_link(page)
    # CSV-to-Popolo runs these through FacebookUsernameExtractor, so
    # we can just strip off the prefix
    return if page.to_s.empty?
    page.sub('https://facebook.com/', '')
  end

  require 'csv'
  desc 'Generate the Term Tables'
  task term_tables: 'ep-popolo-v1.0.json' do
    @json = JSON.parse(File.read('ep-popolo-v1.0.json'), symbolize_names: true)
    popolo = EveryPolitician::Popolo.read('ep-popolo-v1.0.json')
    people = Hash[popolo.persons.map { |p| [p.id, p] }]
    term_end_dates = Hash[popolo.terms.map { |t| [t.id, t.end_date] }]

    data = @json[:memberships].select { |m| m.key? :legislative_period_id }.map do |m|
      person = people[m[:person_id]]
      group  = @json[:organizations].find { |o| (o[:id] == m[:on_behalf_of_id]) || (o[:id].end_with? "/#{m[:on_behalf_of_id]}") }
      house  = @json[:organizations].find { |o| (o[:id] == m[:organization_id]) || (o[:id].end_with? "/#{m[:organization_id]}") }

      if group.nil?
        warn "No group for #{m}"
        binding.pry
        next
      end

      {
        id:         person.id.split('/').last,
        name:       person.name_at(m[:end_date] || term_end_dates[m[:legislative_period_id]]),
        sort_name:  person.sort_name,
        email:      person.email,
        twitter:    person.twitter,
        facebook:   tidy_facebook_link(person.facebook),
        group:      group[:name],
        group_id:   group[:id].split('/').last,
        area_id:    m[:area_id],
        area:       m[:area_id] && @json[:areas].find { |a| a[:id] == m[:area_id] }[:name],
        chamber:    house[:name],
        term:       m[:legislative_period_id].split('/').last,
        start_date: m[:start_date],
        end_date:   m[:end_date],
        image:      person.image,
        gender:     person.gender,
      }
    end

    terms = data.group_by { |r| r[:term] }
    warn "Creating #{terms.count} term file#{terms.count > 1 ? 's' : ''}"
    terms.each do |t, rs|
      filename = "term-#{t}.csv"
      header = rs.first.keys.to_csv
      rows   = rs.portable_sort_by { |r| [r[:name], r[:id], r[:start_date].to_s, r[:area].to_s] }.map { |r| r.values.to_csv }
      csv    = [header, rows].compact.join
      File.write(filename, csv)
    end
  end

  task top_identifiers: :term_tables do
    top_identifiers = @json[:persons].map { |p| (p[:identifiers] || []).map { |i| i[:scheme] } }.flatten
                                     .reject { |i| i == 'everypolitician_legacy' }
                                     .group_by { |i| i }
                                     .sort_by { |_i, is| -is.count }
                                     .take(5)
                                     .map { |i, is| [i, is.count] }

    if top_identifiers.any?
      warn "\nTop identifiers:"
      top_identifiers.each do |i, c|
        warn "  #{c} x #{i}"
      end
      warn "\n"
    end
  end

  task name_list: :top_identifiers do
    names = @json[:persons].flat_map do |p|
      nameset = Set.new([p[:name]])
      nameset.merge (p[:other_names] || []).map { |n| n[:name] }
      nameset.map { |n| [n, p[:id].split('/').last] }
    end.uniq { |name, id| [name.downcase, id] }.sort_by { |name, id| [name.downcase, id] }

    filename = 'names.csv'
    header = %w(name id).to_csv
    csv    = [header, names.map(&:to_csv)].compact.join
    warn "Creating #{filename}"
    File.write(filename, csv)
  end

  desc 'Add some final reporting information'
  task reports: :term_tables do
    wikidata_persons = @json[:persons].partition { |p| (p[:identifiers] || []).find { |i| i[:scheme] == 'wikidata' } }
    wikidata_parties = @json[:organizations].select { |o| o[:classification] == 'party' }
                                            .reject { |p| p[:name].downcase == 'unknown' }
                                            .partition do |p|
      (p[:identifiers] || []).find { |i| i[:scheme] == 'wikidata' }
    end
    matched, unmatched = wikidata_persons.map(&:count)
    warn "Persons matched to Wikidata: #{matched} ✓ #{unmatched.zero? ? '' : "| #{unmatched} ✘"}"
    wikidata_persons.last.shuffle.take(10).each { |p| warn "  No wikidata: #{p[:name]} (#{p[:id]})" } unless matched.zero?

    matched, unmatched = wikidata_parties.map(&:count)
    warn "Parties matched to Wikidata: #{matched} ✓ #{unmatched.zero? ? '' : "| #{unmatched} ✘"}"
    wikidata_parties.last.shuffle.take(5).each { |p| warn "  No wikidata: #{p[:name]} (#{p[:id]})" } unless matched.zero?
  end

  # TODO: move this to its own file
  class PositionFilter
    def initialize(pathname:)
      @pathname = pathname
    end

    def to_json
      return empty_filter unless pathname.exist?
      raw_json
    end

    def to_include
      to_json[:include].map { |_, fs| fs.map { |f| f[:id] } }.flatten.to_set
    end

    def to_exclude
      to_json[:exclude].map { |_, fs| fs.map { |f| f[:id] } }.flatten.to_set
    end

    def cabinet
      (to_json[:include][:cabinet] || []).map { |p| p[:id] }.to_set
    end

    private

    attr_reader :pathname

    def empty_filter
      { exclude: { self: [], other: [] }, include: { self: [], other_legislatures: [], cabinet: [], executive: [], party: [], other: [] } }
    end

    def raw_json
      @json ||= json5_parse(pathname.read).each do |_s, fs|
        fs.each { |_, fs| fs.each { |f| f.delete :count } }
      end
    end

    # TODO: move this to somewhere more generally useful
    def json5_parse(data)
      # read with JSON5 to be more liberal about trailing commas.
      # But that doesn't have a 'symbolize_names' so rountrip through JSON
      JSON.parse(JSON5.parse(data).to_json, symbolize_names: true)
    end
  end

  desc 'Build the Positions file'
  task positions: ['ep-popolo-v1.0.json'] do
    next unless POSITION_RAW.file?
    warn "Creating #{POSITION_CSV}"
    positions = JSON.parse(POSITION_RAW.read, symbolize_names: true)
    position_filter = PositionFilter.new(pathname: POSITION_FILTER)
    filter = position_filter.to_json

    to_include = position_filter.to_include
    to_exclude = position_filter.to_exclude
    cabinet    = position_filter.cabinet

    want, unknown = @json[:persons].map do |p|
      (p[:identifiers] || []).select { |i| i[:scheme] == 'wikidata' }.map do |id|
        positions[id[:identifier].to_sym].to_a.reject { |p| p[:id].nil? }.map do |posn|
          {
            id:          p[:id],
            wikidata:    id[:identifier],
            name:        p[:name],
            position_id: posn[:id],
            position:    posn[:label],
            description: posn[:description],
            start_date:  (posn[:qualifiers] || {})[:P580],
            end_date:    (posn[:qualifiers] || {})[:P582],
          }
        end
      end
    end.flatten(2).reject { |r| to_exclude.include? r[:position_id] }.partition { |r| to_include.include? r[:position_id] }

    want.select { |p| cabinet.include? p[:position_id] }.select { |p| p[:start_date].nil? && p[:end_date].nil? }.each do |p|
      warn "  ☇ No dates for #{p[:name]} (#{p[:wikidata]}) as #{p[:position]}"
    end

    (filter[:unknown] ||= {})[:unknown] = unknown
                                          .group_by { |u| u[:position_id] }
                                          .sort_by { |_u, us| us.first[:position].downcase }
                                          .map { |id, us| { id: id, name: us.first[:position], description: us.first[:description], count: us.count, example: us.first[:wikidata] } }.each do |u|
      warn "  Unknown position (x#{u[:count]}): #{u[:id]} #{u[:name]} — e.g. #{u.delete :example}"
    end

    filter.each do |_, section|
      section.each { |_k, vs| vs.sort_by! { |e| e[:name] } }
    end
    csv_columns = %w(id name position start_date end_date)
    csv = [csv_columns.to_csv, want.map { |p| csv_columns.map { |c| p[c.to_sym] }.to_csv }].compact.join

    POSITION_CSV.dirname.mkpath
    POSITION_CSV.write(csv)
    POSITION_FILTER.write(JSON.pretty_generate(filter))

    if filter[:unknown][:unknown].any? && ENV['GENERATE_POSITION_INTERFACE']
      html = Position::Filterer.new(filter).html
      POSITION_HTML.write(html)
      FileUtils.copy('../../../templates/position-filter.js', 'sources/manual/.position-filter.js')
      warn "open #{POSITION_HTML}".yellow
      warn "pbpaste | bundle exec ruby #{POSITION_LEARNER} #{POSITION_FILTER}".yellow
    end
  end
end
