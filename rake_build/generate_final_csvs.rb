# frozen_string_literal: true

require 'everypolitician/popolo'
require 'json5'
require 'everypolitician/dataview/terms'

desc 'Build the term-table CSVs'
task csvs: ['term_csvs:term_tables', 'term_csvs:name_list', 'term_csvs:positions', 'term_csvs:reports']

CLEAN.include('term-*.csv')

namespace :term_csvs do
  desc 'Generate the Term Tables'
  task term_tables: POPOLO_JSON do
    source_warn 'Creating termfiles'
    @popolo = popolo = EveryPolitician::Popolo.read(POPOLO_JSON)
    terms = EveryPolitician::Dataview::Terms.new(popolo: @popolo).terms
    terms.each do |term|
      path = Pathname.new('term-%s.csv' % term.id)
      path.write(term.as_csv)

      # TODO: make generating latest.csv a separate task
      next unless term.id == terms.last.id

      latest = Pathname.new('unstable/latest.csv')
      today = Date.today.iso8601
      csv = CSV.table(path).delete_if { |r| r[:end_date] && r[:end_date] < today }.tap do |t|
        %i[chamber end_date].each { |col| t.delete(col) }
      end
      popolo_term = popolo.terms.find { |t| t.id.split('/').last == term.id }
      term_start = popolo_term.start_date
      csv.each { |r| r[:start_date] ||= term_start }
      latest.write(csv.to_s)

      term_end = popolo_term.end_date
      warn " *** latest term ended on #{term_end} *** ".red if term_end && term_end < today
    end
  end

  task name_list: :term_tables do
    source_warn "Creating #{NAMES_CSV}"
    names = @popolo.persons.flat_map do |p|
      Set.new([p.name]).merge(p.other_names.map { |n| n[:name] }).map { |n| [n, p.id] }
    end.uniq { |name, id| [name.downcase, id] }.sort_by { |name, id| [name.downcase, id] }

    header = %w[name id].to_csv
    csv    = names.map(&:to_csv).compact.join
    NAMES_CSV.write(header + csv)
  end

  def wikidata_matched(type, partitioned_collection)
    matched, unmatched = partitioned_collection.map(&:count)
    warn "#{type} matched to Wikidata: #{matched} ✓ #{unmatched.zero? ? '' : "| #{unmatched} ✘"}"
    partitioned_collection.last.shuffle.take(10).each { |p| warn "  No wikidata: #{p.name} (#{p.id})" } unless matched.zero?
  end

  desc 'Add some final reporting information'
  task reports: :term_tables do
    warn '-' * 72
    wikidata_matched('Persons', @popolo.persons.partition(&:wikidata))
    wikidata_matched('Areas', @popolo.areas.partition(&:wikidata))
    wikidata_matched('Parties', @popolo.organizations.where(classification: 'party')
                     .reject { |p| p.name.downcase.include? 'unknown' }.partition(&:wikidata))
    wikidata_matched('Terms', @popolo.events.where(classification: 'legislative period').partition(&:wikidata))
  end

  desc 'Build the Cabinet file'
  task positions: [POPOLO_JSON] do
    src = @INSTRUCTIONS.sources_of_type('wikidata-cabinet').first or next
    source_warn "Creating #{POSITION_CSV}"

    pmap = PositionMap::CSV.new(POSITION_FILTER_CSV)
    wanted, unwanted = src.partitioned(position_map: pmap)
    members = @popolo.persons.select(&:wikidata).group_by(&:wikidata)

    csv_headers = %w[id name position start_date end_date type].to_csv
    csv_data = wanted.select { |r| members.key? r[:id] }.map do |r|
      member = members[r[:id]].first
      warn "  ☇ No dates for #{member.name} (#{member.wikidata}) as #{r[:label]}" if r[:start_date].to_s.empty? && r[:end_date].to_s.empty?
      [member.id, member.name, r[:label], r[:start_date], r[:end_date], 'cabinet'].to_csv
    end

    POSITION_CSV.dirname.mkpath
    POSITION_CSV.write(csv_headers + csv_data.join)

    # Warn if the filter still contains non-cabinet positions
    ncps = pmap.non_cabinet_position_ids.to_set
    warn "  † position filter contains non-cabinet positions (#{ncps.count}) — run rake generate:cabinet" if ncps.any?

    # Warn if people hold positions we're not expecting
    skipped = unwanted.reject { |r| ncps.include? r[:position] }.group_by { |r| r[:position] }.sort_by { |_r, rs| rs.count }
    skipped.reverse.take(3).each do |posn, posns|
      warn "  ⁕ skipped #{posns.count} x #{posn} (#{posns.first[:label]}) — e.g. #{posns.first[:id]}"
    end
  end
end

desc 'Convert the old JSON position filter to a CSV'
task :convert_position_filter do
  # for now, simply convert the old JSON file to a new CSV one
  src = @INSTRUCTIONS.sources_of_type('wikidata-cabinet').first or next
  map = PositionMap.new(pathname: POSITION_FILTER)

  csv_headers = %w[id label description type].to_csv
  csv_data = src.as_table.group_by { |r| r[:position] }.map do |id, ps|
    [id, ps.first[:label], ps.first[:description], map.type(id) || 'unknown']
  end.sort_by { |d| [d[3].to_s, d[1].to_s.downcase] }.map(&:to_csv)

  POSITION_FILTER_CSV.dirname.mkpath
  POSITION_FILTER_CSV.write(csv_headers + csv_data.join)
end

desc 'Generate the position filter interface'
task :generate_position_interface do
  abort 'not implemented yet'
  # TODO: make the HTML interface to this again.
  # new_map = PositionMap.new(pathname: POSITION_FILTER).to_json
  # html = Position::Filter::HTML.new(new_map).html
  # POSITION_HTML.write(html)
  # FileUtils.copy('../../../templates/position-filter.js', 'sources/manual/.position-filter.js')
  # warn "open #{POSITION_HTML}".yellow
  # warn "pbpaste | bundle exec ruby #{POSITION_LEARNER} #{POSITION_FILTER}".yellow
end
