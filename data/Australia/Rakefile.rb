require_relative '../../rakefile_morph.rb'

@MORPH = 'tmtmtmtm/popit-australia'
@TERMS = [{ 
  id: 'term/44',
  name: '44th Parliament',
  start_date: '2013-09-07',
}]

namespace :transform do

  # Ensure the Legislature is the parent of the Chambers
  # TODO promote this to a default Rule
  # and leave :rename_chambers as a separate thing
  task :write => :connect_chambers
  task :connect_chambers => :ensure_legislature do
    better_name = { 
      'senate' => 'Senate',
      'representatives' => 'House of Representatives',
    }

    @json[:organizations].find_all { |h| h[:classification] == 'chamber' }.each do |c|
      c[:name] = better_name[c[:name]] || c[:name]
      # FIXME: this shouldn't rely on a specific ID, but find the correct Org
      c[:parent_id] ||= 'legislature'
    end
  end

end
