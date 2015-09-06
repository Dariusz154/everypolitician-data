require 'colorize'
require 'csv'
require 'open-uri'
require 'pry'
require 'rake/clean'
require 'yajl/json_gem'

require_relative 'rakefile_csvs.rb'

Numeric.class_eval { def empty?; false; end }


def deep_sort(element)
  if element.is_a?(Hash)
    element.keys.sort.each_with_object({}) { |k, newhash| newhash[k] = deep_sort(element[k]) }
  elsif element.is_a?(Array)
    element.map { |v| deep_sort(v) }
  else
    element
  end
end

def json_load(file)
  return unless File.exist? file
  JSON.parse(File.read(file), symbolize_names: true)
end

def json_write(file, json)
  # TODO remove the need for the .to_s here, by ensuring all People and Orgs have names
  json[:persons].sort_by!       { |p| [ p[:name].to_s, p[:id] ] }
  json[:organizations].sort_by! { |o| [ o[:name].to_s, o[:id] ] }
  json[:memberships].sort_by!   { |m| [ m[:person_id], m[:organization_id] ] }
  json[:events].sort_by!        { |e| [ e[:start_date] || '', e[:id] ] } if json.key? :events
  json[:areas].sort_by!         { |a| [ a[:id] ] } if json.key? :areas
  final = Hash[deep_sort(json).sort_by { |k, _| k }.reverse]
  File.write(file, JSON.pretty_generate(final))
end

def instructions(key)
  @instructions ||= json_load(@INSTRUCTIONS_FILE) || raise("Can't read #{@INSTRUCTIONS_FILE}")
  @instructions[key]
end

desc "Rebuild from source data"
task :rebuild => [ :clobber, 'ep-popolo-v1.0.json' ]
task :default => :csvs

desc "Remove unwanted data from source"
task :whittle => [:clobber, 'sources/merged.json']

namespace :whittle do

  # Source-specific files must provide a whittle:load

  file 'sources/merged.json' => :write 
  CLEAN.include('sources/merged.json')

  # Source-specific files must provide a @SOURCE

  task :meta_info => :load do
    @json[:meta] ||= {}
    @json[:meta][:source] = @SOURCE || instructions(:source) || abort("No @SOURCE defined")
  end

  # Remove any 'warnings' left behind from (e.g.) csv-to-popolo
  task :write => :remove_warnings
  task :remove_warnings => :load do
    @json.delete :warnings
  end

  # TODO work out how to make this do the 'only run if needed'
  task :write => :meta_info do
    unless File.exists? 'sources/merged.json'
      json_write('sources/merged.json', @json)
    end
  end

  #---------------------------------------------------------------------
  # Rule: No orphaned memberships
  #---------------------------------------------------------------------
  task :write => :no_orphaned_memberships
  task :no_orphaned_memberships => :load do
    @json[:memberships].keep_if { |m|
      @json[:organizations].find { |o| o[:id] == m[:organization_id] } and
      @json[:persons].find { |p| p[:id] == m[:person_id] } 
    }
  end  
end

#-----------------------------------------------------------------------
# Transform the results from generic CSV-to-Popolo into EP-Popolo
#
#   - merge legislature data from meta.json
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
  # Don't duplicate start/end dates into memberships needlessly
  #---------------------------------------------------------------------
  task :write => :tidy_membership_dates
  task :tidy_membership_dates => :ensure_term do
    @json[:memberships].find_all { |m| m[:role] == 'member' and m[:organization_id] == @legislature[:id] }.each do |m|
      e = @json[:events].find { |e| e[:id] == m[:legislative_period_id] } or raise "#{m[:legislative_period_id]} is not a term"
      m.delete :start_date if m[:start_date].to_s == e[:start_date].to_s
      m.delete :end_date   if m[:end_date].to_s   == e[:end_date].to_s
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
    raise "Memberships must all have legislative_periods" if @json[:memberships].any? { |m| m[:legislative_period_id].to_s.empty? }
  end

end
