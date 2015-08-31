
require 'colorize'
require 'csv'
require 'erb'
require 'fileutils'
require 'fuzzy_match'
require 'json'
require 'open-uri'
require 'pry'
require 'rake/clean'
require 'set'

def json_load(file)
  return unless File.exist? file
  JSON.parse(File.read(file), symbolize_names: true)
end

@instructions = json_load('instructions.json') 
raise "No sources" if @instructions[:sources].count.zero?

@recreatable = @instructions[:sources].find_all { |i| i.key? :create }
CLOBBER.include FileList.new(@recreatable.map { |i| i[:file] })

# For now, write the merged file to manual/members.csv so we can then
# fall-back on the old-style rake task that looks there
# TODO: consolidate these
CLOBBER.include 'manual/members.csv'

def morph_select(src, qs)
  morph_api_key = ENV['MORPH_API_KEY'] or fail 'Need a Morph API key'
  key = ERB::Util.url_encode(morph_api_key)
  query = ERB::Util.url_encode(qs.gsub(/\s+/, ' ').strip)
  url = "https://api.morph.io/#{src}/data.csv?key=#{key}&query=#{query}"
  warn "Fetching #{url}"
  open(url).read
end

def fetch_missing
  @recreatable.each do |i|
    unless File.exist? i[:file]
      c = i[:create]
      FileUtils.mkpath File.dirname i[:file]
      if c[:type] == 'morph'
        data = morph_select(c[:scraper], c[:query])
        File.write(i[:file], data)
      elsif c[:type] == 'ocd'
        remote = 'https://raw.githubusercontent.com/opencivicdata/ocd-division-ids/master/identifiers/' + c[:source]
        IO.copy_stream(open(remote), i[:file])
      else
        raise "Don't know how to fetch #{i[:file]}" unless c[:type] == 'morph'
      end
    end
  end 
end

REMAP = {
  area: %w(constituency region district place),
  area_id: %w(constituency_id region_id district_id place_id),
  biography: %w(bio blurb),
  birth_date: %w(dob date_of_birth),
  blog: %w(weblog),
  cell: %w(mob mobile cellphone),
  chamber: %w(house),
  death_date: %w(dod date_of_death),
  end_date: %w(end ended until to),
  executive: %w(post),
  family_name: %w(last_name surname lastname),
  fax: %w(facsimile),
  gender: %w(sex),
  given_name: %w(first_name forename),
  group: %w(party party_name faction faktion bloc block org organization organisation),
  group_id: %w( party_id faction_id faktion_id bloc_id block_id org_id organization_id organisation_id),
  image: %w(img picture photo photograph portrait),
  name: %w(name_en),
  patronymic_name: %w(patronym patronymic),
  phone: %w(tel telephone),
  source: %w(src),
  start_date: %w(start started from since),
  term: %w(legislative_period),
  website: %w(homepage href url site),
}
def remap(str)
  REMAP.find(->{[str]}) { |k, v| v.include? str.to_s }.first.to_sym
end


# Simplest version for now; can evolve over time based on actual usage
class CSVPatch

  def initialize(original)
    @_csv = original
  end

  def patch!(new_row, opts)
    existing_field = opts[:existing_field].to_sym rescue raise("Need an `existing_field` to match on")
    incoming_field = opts[:incoming_field].to_sym rescue raise("Need an `incoming_field` to match on")
    opts[:overrides] ||= {}

    # Short-circuit if we've already been told who this matches
    if exact_match = opts[:overrides][new_row[incoming_field].to_sym]
      to_patch = @_csv.find_all { |r| r[:id] == exact_match }

    # Approximate match?
    elsif opts.key? :amatch_threshold
      # TODO: don't rebuild this this every time around
      fuzzer = FuzzyMatch.new(@_csv, read: existing_field)
      match = fuzzer.find_with_score(new_row[incoming_field])
      confidence = match[1].to_f * 100

      if confidence < opts[:amatch_threshold].to_f
        warn "Too low match for: %s (Best = %s @ %.2f%%)".cyan % [ new_row[incoming_field], match.first[existing_field], confidence ]
        to_patch = []
      else
        warn "Matched %s to %s @ %.2f%%".yellow % [new_row[incoming_field], match.first[existing_field], confidence ] if
          confidence < opts[:amatch_warning].to_f
        to_patch = @_csv.find_all { |r| r[existing_field] == match.first[existing_field] }
      end
    else
      to_patch = @_csv.find_all { |r| r[existing_field] == new_row[incoming_field] }
    end

    if to_patch.empty?
      warn "Can't match row to existing data: #{new_row.to_hash.reject { |k,v| v.to_s.empty? } }".red
    else 
      # warn "Patching #{to_patch.size} rows with #{new_row[incoming_field]}".green
    end
    # For now, only set values that are not already set (or are set to 'unknown')
    # TODO: clobber / append.
    to_patch.each do |existing_row|
      new_row.headers.each do |h| 
        existing_row[h] = new_row[h] if existing_row[h].to_s.empty? || existing_row[h].to_s.downcase == 'unknown' 
      end
    end
  end

  def all_data
    @_csv
  end

end

# http://codereview.stackexchange.com/questions/84290/combining-csvs-using-ruby-to-match-headers
def combine_sources

  # build headers for everything
  all_headers = @instructions[:sources].find_all { |src|
    src[:type] != 'term'
  }. map { |src| src[:file] }.reduce([]) do |all_headers, file|
    # puts "Headers from #{file}".cyan
    header_line = File.open(file, &:gets)     
    all_headers | CSV.parse_line(header_line).map { |h| remap(h.downcase) } 
  end

  # First concat everything that's a "membership" (or default)
  all_rows = []
  @instructions[:sources].find_all { |src|
    src[:type].to_s.empty? || src[:type].to_s.downcase == 'membership'
  }.each do |src| 
    file = src[:file] 
    fuzzer = nil
    puts "Concat #{file}".magenta
    CSV.table(file, converters: nil).each do |row|
      # Need to make a copy in case there are multiple source columns
      # mapping to the same term (e.g. with areas)
      row = Hash[ row.headers.each.map { |h| [ remap(h), row[h] ] } ]

      if src.key? :merge
        field = src[:merge][:field].to_sym
        if src[:merge][:approximate] 
          fuzzer ||= FuzzyMatch.new(all_rows, read: field, must_match_at_least_one_word: true )
          found = fuzzer.find(row[field])
          puts "Matched #{row[field]} to #{found[field]}".yellow
        else
          raise "Not implemented yet"
        end

        if src[:merge][:clobber]
          row.keys.each do |h|
            found[h] = row[h] unless row[h].to_s.empty? || row[h].to_s.downcase == 'unknown'
          end
        else
          raise "Not implemented yet"
        end

      else # append
        all_rows << row.to_hash
      end
    end
  end

  # Then merge with Person data files
  #   existing_field: name — the field name in the existing data to match
  #      previously "field"
  #   incoming_field: name — the field name in the incoming data to match
  #      previously "match_on"
  #
  # For non-exact matching set 'amatch_threshold' to a minimum % score
  # We also warn on any fuzzy match under the 'amatch_warning' % score
  #
  # To override to an exact match, supply the ID of the existing record 
  # e.g. (with incoming_field='name')
  #    "overrides": { "Ian Paisley, Jr.": "13852" }

  @instructions[:sources].find_all { |src| %w(wikidata person).include? src[:type].to_s.downcase }.each do |pd|
    puts "Merging with #{pd[:file]}".magenta

    raise "No merge instructions" unless pd.key?(:merge) 

    persondata = CSV.table(pd[:file], converters: nil)

    if pd[:merge].key? :field
      warn "WARNING deprecated use of merge 'field'. Use 'existing_field' instead".red
      pd[:merge][:existing_field] = pd[:merge].delete :field
    end

    if pd[:merge].key? :match_on
      warn "WARNING deprecated use of merge 'match_on'. Use 'incoming_field' instead".red
      pd[:merge][:incoming_field] = pd[:merge].delete :match_on
    end

    warn "  Match incoming #{pd[:merge][:incoming_field]} to #{pd[:merge][:existing_field]}"

    patcher = CSVPatch.new(all_rows)
    persondata.each { |pd_row| patcher.patch!(pd_row, pd[:merge]) }
    all_rows = patcher.all_data
  end

  # Map Areas 
  # So far only tested with Australia, so super-simple logic. 
  # TOOD: Expand this later
  if area = @instructions[:sources].find { |src| src[:type].to_s.downcase == 'area' } 
    all_headers |= [:area_id]
    ocds = CSV.table(area[:file], converters: nil)
    fuzzer = FuzzyMatch.new(ocds, read: :name)
    finder = ->(r) { fuzzer.find(r[:area], must_match_at_least_one_word: true) }

    override = ->(name) { 
      return unless area[:merge].key? :overrides
      return unless override_id = area[:merge][:overrides][name.to_sym] 
      return '' if override_id.empty?
      ocds.find { |o| o[:id] == override_id } or raise "no match for #{override_id}"
    }

    areas = {}
    all_rows.each do |r|
      raise "existing Area ID: #{r[:area_id]}" if r.key? :area_id
      unless areas.key? r[:area]
        areas[r[:area]] = override.(r[:area]) || finder.(r) 
        if areas[r[:area]].to_s.empty?
          warn "No area match for #{r[:area]}"
        else
          warn "Matched Area %s to %s" % [ r[:area].to_s.yellow, areas[r[:area]][:name].to_s.green ] unless areas[r[:area]][:name].include? " #{r[:area]} "
        end
      end
      next if areas[r[:area]].to_s.empty?
      r[:area_id] = areas[r[:area]][:id] 
    end
  end
  
  # Then write it all out
  FileUtils.mkpath "manual"
  CSV.open("manual/members.csv", "w") do |out|
    out << all_headers
    all_rows.each { |r| out << all_headers.map { |header| r[header.to_sym] } }
  end

  # Write a source file, if required
  # TODO remove this once we're doing everything ourselves

  unless File.exist? 'manual/instructions.json'
    source = { source: @instructions[:sources].first { |i| i[:source] }[:source] }
    File.write 'manual/instructions.json', JSON.pretty_generate(source)
  end

end

task :fetch_missing do
  fetch_missing
end

task 'manual/members.csv' => :fetch_missing do
  combine_sources
end

task :default => [ 'manual/members.csv' ]
