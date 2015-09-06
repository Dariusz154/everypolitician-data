
desc "Generate merged.json"
task :whittle => [:clobber, 'sources/merged.json']

namespace :whittle do

  file 'sources/merged.json' => :write 
  CLEAN.include('sources/merged.json')

  task :load => 'merge_sources:sources/manual/members.csv' do
    @json = Popolo::CSV.new('sources/manual/members.csv').data
  end

  task :meta_info => :load do
    @json[:meta] ||= {}
    # TODO: allow for more than one source
    @json[:meta][:source] = instructions(:sources).map { |s| s[:source] }.compact.first
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


