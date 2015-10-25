
class String
  def tidy
    self.gsub(/[[:space:]]+/, ' ').strip
  end
end

class Fuzzer

  def initialize(existing_rows, incoming_rows, instructions)
    @_existing_rows = existing_rows
    @_incoming_rows = incoming_rows
    @_instructions  = instructions
    @_existing_field = instructions[:existing_field].to_sym rescue raise("Need an `existing_field` to match on")
    @_incoming_field = instructions[:incoming_field].to_sym rescue raise("Need an `incoming_field` to match on")
  end

  def fuzzer
    @_fuzzer ||= FuzzyMatch.new(@_existing_rows, read: @_existing_field)
  end

  def find_all
    @_incoming_rows.map do |incoming_row|
      if incoming_row[@_incoming_field].to_s.empty?
        warn "No #{@_incoming_field} in #{incoming_row}".red 
        nil
      else 
        match = fuzzer.find_with_score(incoming_row[@_incoming_field]) 
        unless match
          warn "No matches for #{incoming_row}"
          next
        end
        matched_id = match.first.key?(:id)? match.first[:id] : nil
        data = [ incoming_row[@_incoming_field], match.first[@_existing_field], matched_id, match[1].to_f * 100 ]
        warn "Fuzzed #{data.to_s}"
        data
      end
    end.compact
  end

end

class Reconciler

  def initialize(existing_rows, instructions, precanned)
    @_existing_rows = existing_rows
    @_instructions  = instructions
    warn "Deprecated use of 'overrides'".cyan if @_instructions.include? :overrides
    @_existing_field = instructions[:existing_field].to_sym rescue raise("Need an `existing_field` to match on")
    @_incoming_field = instructions[:incoming_field].to_sym rescue raise("Need an `incoming_field` to match on")
   
    @_instructions[:overrides] = precanned ? Hash[precanned.map { |r| [r.to_hash.values[0], r.to_hash] }] : {}
  end

  def existing
    @_lookup ||= @_existing_rows.group_by { |r| r[@_existing_field].to_s.downcase }
  end

  def existing_by_id
    @_lookup_by_id ||= @_existing_rows.group_by { |r| r[:id].to_s }
  end

  def find_all(incoming_row)
    if incoming_row[@_incoming_field].to_s.empty?
      warn "#{incoming_row.reject { |k, v| v.nil? }} has no #{@_incoming_field}" 
      return []
    end

    # Short-circuit if we've already been told who this matches (either by ID or field)
    if preset = @_instructions[:overrides][incoming_row[@_incoming_field]]
      return existing_by_id[ preset[:id].to_s ] if preset[:id] 
      return existing[ preset[ "existing_#{@_existing_field}".to_sym ].downcase ] 
    end

    if exact_match = existing[ incoming_row[@_incoming_field].downcase ]
      return exact_match
    end

    return []

  end

end

namespace :merge_sources do

  task :fetch_missing do
    fetch_missing
  end

  desc "Combine Sources"
  task 'sources/merged.csv' => :fetch_missing do
    combine_sources
  end

  @recreatable = instructions(:sources).find_all { |i| i.key? :create }
  CLOBBER.include FileList.new(@recreatable.map { |i| i[:file] })

  CLEAN.include 'sources/merged.csv'

  def morph_select(src, qs)
    morph_api_key = ENV['MORPH_API_KEY'] or fail 'Need a Morph API key'
    key = ERB::Util.url_encode(morph_api_key)
    query = ERB::Util.url_encode(qs.gsub(/\s+/, ' ').strip)
    url = "https://api.morph.io/#{src}/data.csv?key=#{key}&query=#{query}"
    open(url).read
  end

  def fetch_missing
    @recreatable.each do |i|
      unless File.exist? i[:file]
        c = i[:create]
        FileUtils.mkpath File.dirname i[:file]
        warn "Regenerating #{i[:file]}"
        if c.key? :url
          IO.copy_stream(open(c[:url]), i[:file])
        elsif c[:type] == 'morph'
          data = morph_select(c[:scraper], c[:query])
          File.write(i[:file], data)
        elsif c[:type] == 'parlparse'
          instructions = json_load("sources/#{c[:instructions]}")

          gh_url = 'https://raw.githubusercontent.com/everypolitician/everypolitician-data/master/data/'
          term_file_url = gh_url + '%s/sources/manual/terms.csv'
          instructions_url = gh_url + '%s/sources/parlparse/instructions.json'
          cwd = pwd.split("/").last(2).join("/")

          args = { 
            terms_csv: term_file_url % cwd,
            instructions_json: instructions_url % cwd,
          }
          remote = 'https://parlparse-to-csv.herokuapp.com/?' + URI.encode_www_form(args)
          IO.copy_stream(open(remote), i[:file])
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

  # http://codereview.stackexchange.com/questions/84290/combining-csvs-using-ruby-to-match-headers
  def combine_sources

    # Build the master list of columns
    all_headers = instructions(:sources).find_all { |src|
      src[:type] != 'term'
    }. map { |src| src[:file] }.reduce([]) do |all_headers, file|
      header_line = File.open(file, &:gets)     
      all_headers | CSV.parse_line(header_line).map { |h| remap(h.downcase) } 
    end

    merged_rows = []

    # Make sure all instructions have a `type`
    if (no_type = instructions(:sources).find { |src| src[:type].to_s.empty? })
      raise "Missing `type` in #{no_type} file"
    end

    # First get all the `membership` rows. 
    # Assume for now that each is unique, and simply concat them
   
    instructions(:sources).find_all { |src| src[:type].to_s.downcase == 'membership' }.each do |src| 
      file = src[:file] 
      puts "Add memberships from #{file}".magenta
      csv_table(file).each do |row|
        merged_rows << row.to_hash
      end
    end

    # Then merge with Person data files
    #   existing_field: the field in the existing data to match to
    #   incoming_field: the field in the incoming data to match with

    instructions(:sources).find_all { |src| %w(wikidata person).include? src[:type].to_s.downcase }.each do |pd|
      puts "Merging with #{pd[:file]}".magenta
      raise "No merge instructions" unless pd.key?(:merge) 

      all_headers |= [:identifier__wikidata] if pd[:type] == 'wikidata'

      incoming_data = csv_table(pd[:file])
      
      approaches = pd[:merge].class == Hash ? [pd[:merge]] : pd[:merge]
      approaches.each do |merger|
        warn "  Match incoming #{merger[:incoming_field]} to #{merger[:existing_field]}"
        merger[:report_missing] = true unless merger.key? :report_missing

        # TODO complain if this isn't the last step — all prior ones
        # should be exact matches
        if rec_file = merger[:reconciliation_file]
          rec_filename = File.join "sources", rec_file

          incoming_fieldname = "incoming_" + merger[:incoming_field]
          existing_fieldname = "existing_" + merger[:existing_field]

          if File.exist? rec_filename
            reconciled = CSV.table(rec_filename)
          else
            warn "Need to create #{rec_file}".cyan
            fuzzer = Fuzzer.new(merged_rows, incoming_data, merger)
            matched = fuzzer.find_all.sort_by { |m| m.last }.reverse
            FileUtils.mkpath File.dirname rec_filename
            CSV.open(rec_filename, "wb") do |csv|
              csv << [incoming_fieldname, existing_fieldname, 'id', 'confidence']
              matched.each { |match| csv << match unless match[0].downcase == match[1].downcase }
            end
            abort "Created #{rec_filename} — please check it and re-run".green
          end
        end

        
        unmatched = []
        reconciler = Reconciler.new(merged_rows, merger, reconciled)
        incoming_data.each do |incoming_row|

          incoming_row[:identifier__wikidata] ||= incoming_row[:id] if pd[:type] == 'wikidata'

          # TODO factor this out to a Patcher again
          to_patch = reconciler.find_all(incoming_row)
          if to_patch && !to_patch.size.zero?
            # Be careful to take a copy and not delete from the core list
            to_patch = to_patch.select { |r| r[:term].to_s == incoming_row[:term].to_s } if merger[:term_match] 
            uids = to_patch.map { |r| r[:id] }.uniq
            if uids.count > 1
              warn "Too many IDs: #{uids}".red.on_yellow
              # binding.pry
              next
            end
            to_patch.each do |existing_row|
              # For now, only set values that are not already set (or are set to 'unknown')
              # TODO: have a 'clobber' flag (or list of values to trust the latter source for)
              incoming_row.keys.each do |h| 
                existing_row[h] = incoming_row[h] if existing_row[h].to_s.empty? || existing_row[h].to_s.downcase == 'unknown' 
              end
            end
          else
            warn "Can't match row to existing data: #{incoming_row.to_hash.reject { |k,v| v.to_s.empty? } }".red if merger[:report_missing]
            unmatched << incoming_row
          end
        end
        puts "* %d of %d unmatched".magenta % [unmatched.count, incoming_data.count]
        incoming_data = unmatched
      end
    end

    # Map Areas 
    if area = instructions(:sources).find { |src| src[:type].to_s.downcase == 'area' } 
      ocds = CSV.table(area[:file], converters: nil).group_by { |r| r[:id] }

      all_headers |= [:area, :area_id]

      if area[:generate] == 'area'
        merged_rows.each do |r|
          r[:area] = ocds[r[:area_id]].first[:name] rescue nil
        end

      else 
        # Generate IDs from names
        # So far only tested with Australia, so super-simple logic. 
        # TOOD: Expand this later

        fuzzer = FuzzyMatch.new(ocds.values.flatten(1), read: :name)
        finder = ->(r) { fuzzer.find(r[:area], must_match_at_least_one_word: true) }

        override = ->(name) { 
          return unless area[:merge].key? :overrides
          return unless override_id = area[:merge][:overrides][name.to_sym] 
          return '' if override_id.empty?
          binding.pry
          # FIXME look up in Hash instead
          # ocds.find { |o| o[:id] == override_id } or raise "no match for #{override_id}"
        }

        areas = {}
        merged_rows.each do |r|
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
    end
    
    # Then write it all out
    CSV.open("sources/merged.csv", "w") do |out|
      out << all_headers
      merged_rows.each { |r| out << all_headers.map { |header| r[header.to_sym] } }
    end

  end

end
