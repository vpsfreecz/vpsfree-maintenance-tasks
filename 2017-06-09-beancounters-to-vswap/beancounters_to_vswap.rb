#!/usr/bin/env ruby
# This script replaces privvmpages based config with a new vSwap one.
# Memory limits configured using configs are converted to vpsAdmin
# cluster resources.
#
# The configuration change occurs during the outage windows, users
# are e-mailed upfront using templates configured below.

### CONFIGURABLES
BASE_PRIVVM_CFG = 1
BASE_VSWAP_CFG = 27
TR = {
    'privvmpages-4g-6g' => 4*1024,
    'privvmpages-6g-6g' => 6*1024,
    'privvmpages-8g-8g' => 8*1024,
}
###

Dir.chdir('/opt/vpsadmin-api')
require '/opt/vpsadmin-api/lib/vpsadmin'

SUBJ = {
    en: '[vpsFree.cz] Maintenance on VPS #<%= @vps.id %>',
    cs: '[vpsFree.cz] Úprava konfigurace VPS #<%= @vps.id %>',
}

MAIL = {}
MAIL[:cs] = <<END
Ahoj <%= @user.login %>,

VPS #<%= @vps.id %> na <%= @vps.node.domain_name %> stále využívá starou metodu konfigurace paměti,
tzv. user beancounters, kde se nepočítá jen využitá paměť, ale i všechna
alokovaná paměť. V době nejbližšiho možného nastaveného okna pro výpadky dojde
k úpravě konfigurace na novější metodu účtování paměti, tzv. vSwap, který
využívají všechny nové VPS.

Ve VPS se změna konfigurace projeví jednoduše jako restart systému. VPS bude
fungovat jako dřív, ale bude možné alokovat více paměti. Restart VPS proběhne
v nejbližším možném termínu:

<% days = %i(Ne Po Út St Čt Pá So) -%>
<% @vps.vps_outage_windows.where(is_open: true).order('weekday').each do |w| -%>
- <%= days[w.weekday] %> od <%= sprintf('%02d:%02d', w.opens_at / 60, w.opens_at % 60) %> do <%= sprintf('%02d:%02d', w.closes_at / 60, w.closes_at % 60) %>
<% end -%>

Žádná akce z Tvé strany není potřeba.

S pozdravem

vpsAdmin @ vpsFree.cz
END

MAIL[:en] = <<END
Hi <%= @user.login %>,

VPS #<%= @vps.id %> na <%= @vps.node.domain_name %> is still using the old method of memory configuration,
user beancounters, which accounts not only used memory, but also all allocated
memory. During the closest configured outage window, the VPS will be
reconfigured to use a newer memory accounting method called vSwap, which
accounts only used memory, not allocated. All new VPS are configured with vSwap.

The VPS will see the configuration change as a system restart. The VPS will
function just as before, but you'll be able to allocate more memory. The restart
will occur in the closest outage window:

<% days = %i(Sun Mon Tue Wed Thu Fri Sat) -%>
<% @vps.vps_outage_windows.where(is_open: true).order('weekday').each do |w| -%>
- <%= days[w.weekday] %> od <%= sprintf('%02d:%02d', w.opens_at / 60, w.opens_at % 60) %> do <%= sprintf('%02d:%02d', w.closes_at / 60, w.closes_at % 60) %>
<% end -%>

No action from you is required.

Best regards,

vpsAdmin @ vpsFree.cz
END

module TransactionChains
  module Maintenance
    remove_const(:Custom)

    class Custom < TransactionChain
      label 'Change config'

      def link_chain(vps)
        puts "VPS #{vps.id}"
        concerns(:affect, [vps.class.name, vps.id])

        mail_custom(
            from: 'podpora@vpsfree.cz',
            user: vps.user,
            role: :admin,
            subject: SUBJ[vps.user.language.code.to_sym],
            text_plain: MAIL[vps.user.language.code.to_sym],
            vars: {
                user: vps.user,
                vps: vps,
            },
        )

        new_configs = []
        resources = nil

        vps.vps_has_configs.each do |cfg|
          if cfg.vps_config_id == BASE_PRIVVM_CFG
            puts "  Replacing base config #{cfg.vps_config.name}"
            new_configs << BASE_VSWAP_CFG

          elsif TR[cfg.vps_config.name]
            puts "  Replacing memory config #{cfg.vps_config.name}"
            resources = vps.reallocate_resources(
                {memory: TR[cfg.vps_config.name]},
                vps.user,
                chain: self,
                override: true,
            )

          else
            new_configs << cfg.vps_config_id
          end
        end

        append(Transactions::OutageWindow::Wait, args: [vps, 2])
        use_chain(Vps::Stop, args: [vps])
        use_chain(Vps::ApplyConfig, args: [vps, new_configs, resources: false])

        if resources.nil?
          fail "no resources to set for VPS ##{vps.id}"
        end

        use_chain(Vps::SetResources, args: [vps, resources])
        use_chain(Vps::Start, args: [vps]) if vps.is_running?
      end
    end
  end
end

::Vps.joins(:vps_has_configs).where(
    vps_has_configs: {vps_config_id: BASE_PRIVVM_CFG},
).where(
    'object_state < ?', ::Vps.object_states[:soft_delete]
).order('vpses.id').each do |vps|
  TransactionChains::Maintenance::Custom.fire(vps)
end
