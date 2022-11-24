#!/run/current-system/sw/bin/vpsadmin-api-ruby
# Restart VPS during a custom maintenance window
#
# Usage: $0 <vps-id> <weekday> <minutes>
#

require 'vpsadmin'


SUBJ = {
  cs: "[vpsFree.cz] Naplánovaný restart VPS <%= @vps.id %>",
  en: "[vpsFree.cz] Scheduled reboot of VPS <%= @vps.id %>",
}
MAIL = {}
MAIL[:cs] = <<END
Ahoj <%= @user.login %>,

<% prep = %i(v      v       v     ve     ve      v) -%>
<% days = %i(neděli pondělí úterý středu čtvrtek pátek) -%>
VPS <%= @vps.id %> <%= @vps.hostname %> obsahuje vysoký počet zombie procesů
(> 10 000) a z provozních důvodů jej budeme <%= prep[@finish_weekday] %> <%= days[@finish_weekday] %> <%= sprintf('%02d:%02d', @finish_minutes / 60, @finish_minutes % 60) %> restartovat.

Zombie procesy se VPS hromadí buď protože je nevyzvedává rodičovský proces,
nebo nepracuje správně init systém.

V případě, že by Ti restart v tuto dobu nevyhovoval, odepiš prosím na tento
e-mail.

S pozdravem,
tým vpsFree.cz
END

MAIL[:en] = <<END
Hi <%= @user.login %>,

<% days = %i(Sunday Monday Tuesday Wednesday Thursday Friday Saturday) -%>
VPS <%= @vps.id %> <%= @vps.hostname %> has a large amount of zombie processes
(> 10 000) and we're going to reboot it on <%= days[@finish_weekday] %> <%= sprintf('%02d:%02d', @finish_minutes / 60, @finish_minutes % 60) %> for operational reasons.

Zombie processes accumulate inside the VPS either because the parent process
is not waiting on them, or the init system itself has malfunctioned.

In case the date and time wouldn't be convenient for you, please reply to this
e-mail.

Best regards,

vpsFree.cz team
END

module TransactionChains
  module Maintenance
    remove_const(:Custom)

    class Custom < TransactionChain
      label 'Restart'

      def link_chain(vps_id, finish_weekday, finish_minutes)
        vps = ::Vps.find(vps_id)

        lang_code = vps.user.language.code.to_sym
        
        unless SUBJ.has_key?(lang_code)
          puts "VPS #{vps.id} - translation not found"
          return
        end

        puts "VPS #{vps.id} #{vps.hostname} #{vps.node.domain_name} #{vps.user.login}"
  
        maintenance_windows = make_maintenance_windows(
          vps,
          finish_weekday: finish_weekday,
          finish_minutes: finish_minutes,
        )

        mail_custom(
          from: 'podpora@vpsfree.cz',
          reply_to: 'podpora@vpsfree.cz',
          user: vps.user,
          role: :admin,
          subject: SUBJ[lang_code],
          text_plain: MAIL[lang_code],
          vars: {
            user: vps.user,
            vps: vps,
            finish_weekday: finish_weekday,
            finish_minutes: finish_minutes,
          },
        )

        append_t(
          Transactions::MaintenanceWindow::Wait,
          args: [vps, 15],
          kwargs: {maintenance_windows: maintenance_windows},
        )
        append_t(Transactions::Vps::Restart, args: [vps])
      end

      protected
      # Generate maintenance windows specific for this migration
      # @return [Array<VpsMaintenanceWindow>] a list of temporary maintenance windows
      def make_maintenance_windows(vps, **opts)
        # The first open day is finish_weekday. Days after finish_weekday are
        # completely open as well. Days until finish_weekday remain closed.
        windows = (0..6).map do |i|
          ::VpsMaintenanceWindow.new(
            vps: vps,
            weekday: i,
          )
        end

        finish_day = windows[ opts[:finish_weekday] ]
        finish_day.assign_attributes(
          is_open: true,
          opens_at: opts[:finish_minutes],
          closes_at: 24*60,
        )

        cur_day = Time.now.wday

        if cur_day == finish_day.weekday
          # The window is today, therefore all days are open
          windows.each do |w|
            next if w.weekday == finish_day.weekday

            w.assign_attributes(
              is_open: true,
              opens_at: 0,
              closes_at: 24*60,
            )
          end

        else
          7.times do |day|
            next if day == finish_day.weekday

            is_open =
              if cur_day < finish_day.weekday
                # The window opens later this week:
                #  - the days before cur_day (next week) are open
                #  - the days after finish_day this week are open
                day < cur_day || day >= finish_day.weekday
              else
                # The window opens next week
                #  - the days next week after finish_day but before cur_day are open
                day >= finish_day.weekday && day < cur_day
              end

            if is_open
              windows[day].assign_attributes(
                is_open: true,
                opens_at: 0,
                closes_at: 24*60,
              )
            else
              windows[day].assign_attributes(
                is_open: false,
                opens_at: nil,
                closes_at: nil,
              )
            end
          end
        end

        windows.delete_if { |w| !w.is_open }

        unless windows.detect { |w| w.is_open }
          fail 'programming error: no maintenance window is open'
        end

        windows
      end
    end
  end
end

if ARGV.size != 3
  warn "Usage: #{$0} <vps-id> <weekday> <minutes>"
  exit(false)
end

TransactionChains::Maintenance::Custom.fire(ARGV[0].to_i, ARGV[1].to_i, ARGV[2].to_i)
