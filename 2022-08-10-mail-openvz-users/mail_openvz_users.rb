#!/run/current-system/sw/bin/vpsadmin-api-ruby
require 'vpsadmin'

if ARGV.length != 1
  warn "Usage: #{$0} <sent list file>"
  exit(false)
end

SENT_LIST_PATH = ARGV[0]

SUBJ = {
  cs: "[vpsFree.cz] Možnost migrace VPS <%= @vps.id %> na vpsAdminOS",
}
MAIL = {}
MAIL[:cs] = <<END
Ahoj <%= @user.login %>,

všimli jsme si, že VPS #<%= @vps.id %> - <%= @vps.hostname %> u vpsFree.cz máš stále na staré platformě OpenVZ Legacy.
Již nějakou dobu je k dispozici novější a udržované prostředí pro tvůj VPS:

https://blog.vpsfree.cz/migrujte-na-vpsadminos-uz-je-cas-na-aktualni-virtualizaci-s-novym-jadrem/

Co Ti brání v migraci a jak bychom Ti případně mohli pomoci?

S pozdravem,

tým vpsFree.cz
END

module TransactionChains
  module Maintenance
    remove_const(:Custom)

    class Custom < TransactionChain
      label 'Notice'

      def link_chain
        begin
          sent_list = IO.readlines(SENT_LIST_PATH, chomp: true).map(&:to_i)
        rescue Errno::ENOENT
          sent_list = []
        end

        f = File.open(SENT_LIST_PATH, 'a')
        cnt = 0

        ::Vps.joins(:user, :node).where(
          users: {object_state: ::User.object_states[:active], level: 2},
          vpses: {object_state: ::Vps.object_states[:active]},
          nodes: {hypervisor_type: ::Node.hypervisor_types[:openvz]}
        ).order('vpses.id').each do |vps|
          lang_code = vps.user.language.code.to_sym
          
          unless SUBJ.has_key?(lang_code)
            puts "VPS #{vps.id} - translation not found"
            next
          end

          next if sent_list.include?(vps.id)

          puts "VPS #{vps.id} #{vps.hostname} #{vps.node.domain_name} #{vps.user.login}"

          mail_custom(
            from: 'podpora@vpsfree.cz',
            reply_to: 'podpora@vpsfree.cz',
            user: vps.user,
            role: :admin,
            subject: SUBJ[lang_code],
            text_plain: MAIL[lang_code],
            vars: {user: vps.user, vps: vps},
          )

          f.puts(vps.id.to_s)
          cnt += 1

          break if cnt >= 100
        end

        f.close

        fail 'not yet bro'
      end
    end
  end
end

TransactionChains::Maintenance::Custom.fire
