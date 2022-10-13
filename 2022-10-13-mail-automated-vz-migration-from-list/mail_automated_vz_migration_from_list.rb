#!/run/current-system/sw/bin/vpsadmin-api-ruby
#!/run/current-system/sw/bin/vpsadmin-api-ruby
# Usage: $0 <file with vps ids> <start date in YYYY-MM-DD> <number of vps per day> <max days> <out dir>
#
require 'vpsadmin'
require 'time'
require 'fileutils'

SUBJ = {
  cs: "[vpsFree.cz] Naplánovaná automatická migrace VPS <%= @vps.id %> na vpsAdminOS",
  en: "[vpsFree.cz] Scheduled migration of VPS <%= @vps.id %> to vpsAdminOS",
}
MAIL = {}
MAIL[:cs] = <<END
Ahoj <%= @user.login %>, 

nastal čas automatické migrace Tvého VPS #<%= @vps.id %> - <%= @vps.hostname %>
u vpsFree.cz na vpsAdminOS v průběhu dne <%= @date %>.

V případě zájmu se s námi můžeš na migraci domluvit na nějaké konkrétní datum
a čas, kdy budeš moct zkontrovat, že všechno funguje tak, jak má.

Pokud bys chtěl migraci odložit, kontaktuj nás prosím.

Na našem blogu popisujeme proč pospícháme a jak migrace probíhá:

  https://blog.vpsfree.cz/inovujeme-skoro-vsechen-hardware-chceme-byt-energeticky-uspornejsi/

  https://blog.vpsfree.cz/migrujte-na-vpsadminos-uz-je-cas-na-aktualni-virtualizaci-s-novym-jadrem/

S pozdravem, 

tým vpsFree.cz
END

MAIL[:en] = <<END
Hi <%= @user.login %>,

we'd like to inform you that VPS #<%= @vps.id %> - <%= @vps.hostname %>
at vpsFree.cz will be automatically migrated to vpsAdminOS on <%= @date %>.

Should you wish, we can plan the migration at a time of your choosing, when you
could verify that everything works as expected.

If you'd like to postpone the migration, please contact us.

For more information about the migration, see our knowledge base:

  https://kb.vpsfree.org/manuals/vps/vpsadminos

Blog posts describing the need for haste, although only in Czech:

  https://blog.vpsfree.cz/inovujeme-skoro-vsechen-hardware-chceme-byt-energeticky-uspornejsi/

  https://blog.vpsfree.cz/migrujte-na-vpsadminos-uz-je-cas-na-aktualni-virtualizaci-s-novym-jadrem/

Best regards,

vpsFree.cz team
END

module TransactionChains
  module Maintenance
    remove_const(:Custom)

    class Custom < TransactionChain
      label 'Notice'

      def link_chain(vps_id_file, start_date, perday_cnt, max_days, out_dir)
        vps_ids = []
        
        File.open(vps_id_file) do |f|
          f.each_line { |line| vps_ids << line.strip.to_i }
        end

        # Create per-day groups
        cur_day = nil
        days = []

        vps_ids.each do |vps_id|
          vps = ::Vps.find(vps_id)

          if vps.node.hypervisor_type != 'openvz'
            puts "VPS #{vps.id} - not on an OpenVZ node"
            next
          end

          lang_code = vps.user.language.code.to_sym
          
          unless SUBJ.has_key?(lang_code)
            puts "VPS #{vps.id} - translation not found"
            next
          end

          puts "VPS #{vps.id} #{vps.hostname} #{vps.node.domain_name} #{vps.user.login}"

          if cur_day.nil?
            cur_day = {
              date: start_date,
              vpses: [vps],
            }

          elsif cur_day[:vpses].length >= perday_cnt
            days << cur_day

            break if days.length >= max_days
            
            cur_day = {
              date: start_date + (days.length * 24*60*60),
              vpses: [vps],
            }

          else
            cur_day[:vpses] << vps
          end
        end

        days << cur_day if cur_day

        # Print & ask for confirmation
        puts
        puts

        days.each do |day|
          puts "Day #{day[:date].strftime('%d.%m.%Y')} (#{day[:vpses].length} VPS)"
          day[:vpses].each do |vps|
            puts "  VPS #{vps.id} #{vps.hostname} #{vps.node.domain_name} #{vps.user.login}"
          end
        end

        puts
        puts
        puts "Continue? [y/N]:"

        fail 'aborting' if STDIN.readline.strip.downcase != 'y'

        # Execute
        FileUtils.mkdir_p(out_dir)

        days.each do |day|  
          File.open(File.join(out_dir, "#{day[:date].strftime('%Y-%m-%d')}.txt"), 'w') do |f|
            day[:vpses].each do |vps|
              f.puts(vps.id.to_s)
            end
          end

          day[:vpses].each do |vps|
            lang_code = vps.user.language.code.to_sym

            mail_custom(
              from: 'podpora@vpsfree.cz',
              reply_to: 'podpora@vpsfree.cz',
              user: vps.user,
              role: :admin,
              subject: SUBJ[lang_code],
              text_plain: MAIL[lang_code],
              vars: {user: vps.user, vps: vps, date: day[:date].strftime('%d.%m.%Y')},
            )
          end
        end

        fail 'not yet bro'
      end
    end
  end
end

if ARGV.length != 5
  warn "Usage: #{$0} <file with vps ids> <start date in YYYY-MM-DD> <number of vps per day> <max days> <out dir>"
  exit(false)
end

vps_file = ARGV[0]
start_date = Time.strptime(ARGV[1], '%Y-%m-%d')
perday_cnt = ARGV[2].to_i
max_days = ARGV[3].to_i
out_dir = ARGV[4]

TransactionChains::Maintenance::Custom.fire(vps_file, start_date, perday_cnt, max_days, out_dir)
