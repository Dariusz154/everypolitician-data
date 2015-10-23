
#-----------------------------------------------------------------------
# Transform the results from generic CSV-to-Popolo into EP-Popolo
#
#   - remove all Executive Memberships
#   - merge legislature data from meta.json
#     - ensure all legislative memberships are on that
#   - merge term data from terms.csv
#-----------------------------------------------------------------------
namespace :transform do

  file 'ep-popolo-v1.0.json' => :write
  CLEAN.include('ep-popolo-v1.0.json', 'final.json')

  task :load => 'sources/merged.json' do
    @json = JSON.parse(File.read('sources/merged.json'), symbolize_names: true )
  end

  task :write do
    json_write('ep-popolo-v1.0.json', @json)
  end  

  #---------------------------------------------------------------------
  # Rule: There must be a single legislature
  #---------------------------------------------------------------------
  task :write => :ensure_legislature
  task :ensure_legislature => :load do
    legis = @json[:organizations].find_all { |h| h[:classification] == 'legislature' }
    raise "Legislature count = #{count}" unless legis.count == 1
    @legislature = legis.first

    # Remake 'chamber' memberships to the full legislature
    @json[:organizations].select { |h| h[:classification] == 'chamber' }.each do |c|
      @json[:memberships].find_all { |m| m[:organization_id] == c[:id] }.each do |m|
        m[:organization_id] = @legislature[:id]
      end
    end
    @json[:organizations].delete_if { |h| h[:classification] == 'chamber' }

  end

  #---------------------------------------------------------------------
  # Set legislature data from meta.json file
  #---------------------------------------------------------------------
  task :write => :name_legislature
  task :name_legislature => :ensure_legislature do
    raise "No meta.json file available" unless File.exist? 'meta.json'
    meta_info = json_load('meta.json')
    @legislature.merge! meta_info
    (@legislature[:identifiers] ||= []) << { 
      scheme: 'wikidata',
      identifier: @legislature.delete(:wikidata)
    } if @legislature.key?(:wikidata)
  end

  #---------------------------------------------------------------------
  # Merge with terms.csv
  #---------------------------------------------------------------------
  task :write => :ensure_term

  def terms_from_csv
    termfiles = Dir.glob("sources/**/terms.csv")
    raise "No terms.csv" if termfiles.count.zero?
    raise "Too many terms.csv [#{termfiles}]" if termfiles.count > 1

    CSV.read(termfiles.first, headers:true).map do |row|
      {
        id: row['id'][/\//] ? row['id'] : "term/#{row['id']}",
        name: row['name'],
        start_date: row['start_date'],
        end_date: row['end_date'],
        wikidata: row['wikidata'],
        classification: 'legislative period',
        organization_id: @legislature[:id]
      }.reject { |_,v| v.nil? or v.empty? }
    end
  end

  task :ensure_term => :ensure_legislature do
    @json[:events] ||= []

    terms_from_csv.each do |t| 
      if event = @json[:events].find { |e| e[:id] == t[:id] }
        event.merge! t
      else 
        warn "Unused event: #{t}"
      end
    end

  end

  #---------------------------------------------------------------------
  # Remove all other memberships.
  # Don't duplicate start/end dates into memberships needlessly
  #   and ensure they're within the term
  #---------------------------------------------------------------------
  task :write => :tidy_memberships
  task :tidy_memberships => :ensure_term do
    @json[:memberships].keep_if { |m| m[:role] == 'member' and m[:organization_id] == @legislature[:id] }.each do |m|
      e = @json[:events].find { |e| e[:id] == m[:legislative_period_id] } or raise "#{m[:legislative_period_id]} is not a term"
      m.delete :start_date if m[:start_date].to_s <= e[:start_date].to_s 
      m.delete :end_date   if m[:end_date].to_s   >= e[:end_date].to_s 
    end
  end

  #---------------------------------------------------------------------
  # Rule: Legislative Memberships must have `on_behalf_of`
  #---------------------------------------------------------------------
  def unknown_party
    if unknown = @json[:organizations].find { |o| o[:classification] == 'party' and o[:name].downcase == 'unknown' }
      return unknown
    end
    unknown = {
      classification: "party",
      name: "Unknown",
      id: "party/_unknown",
    }
    @json[:organizations] << unknown
    unknown
  end

  task :write => :ensure_behalf_of
  task :ensure_behalf_of => :ensure_legislature do
    leg_ids = @json[:organizations].find_all { |o| %w(legislature chamber).include? o[:classification] }.map { |o| o[:id] }
    @json[:memberships].find_all { |m| m[:role] == 'member' and leg_ids.include? m[:organization_id] }.each do |m|
      m[:on_behalf_of_id] = unknown_party[:id] if m[:on_behalf_of_id].to_s.empty?
    end
  end

  #---------------------------------------------------------------------
  # Rule: Areas should be first class, not just embedded
  #---------------------------------------------------------------------
  task :write => :check_no_embedded_areas 
  task :check_no_embedded_areas => :ensure_legislature do
    raise "Memberships should not have embedded areas" if @json[:memberships].any? { |m| m.key? :area }
  end

end
