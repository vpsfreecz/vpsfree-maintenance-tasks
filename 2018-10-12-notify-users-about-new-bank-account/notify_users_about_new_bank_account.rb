#!/usr/bin/env ruby
# Send an e-mail to all users with the last payment in EUR to let them know
# that we have a new bank account.

Dir.chdir('/opt/vpsadmin/api')
require '/opt/vpsadmin/api/lib/vpsadmin'

# Necessary to load plugins
VpsAdmin::API.default

CURRENCY = 'EUR'

SUBJ = {
  cs: "[vpsFree.cz] Změna bankovního účtu pro platby v #{CURRENCY}",
  en: "[vpsFree.cz] Change of bank account for payments in #{CURRENCY}",
}

MAIL = {}
MAIL[:cs] = <<END
Ahoj <%= @user.login %>,

rádi bychom Tě upozornili na změnu bankovního účtu pro platby členských
příspěvků v EUR:

  SK20 8330 0000 0026 0150 2873
  BIC: FIOZSKBA
  https://ib.fio.cz/ib/transparent?a=2601502873

Původní účet bude stále fungovat, ale pro budoucí platby už jej prosím
nepoužívej. Nový účet je veden v EUR, aby nám pomohl ušetřit peníze
při převádění do CZK a zpět.

S pozdravem

vpsAdmin @ vpsFree.cz
END

MAIL[:en] = <<END
Hi <%= @user.login %>,

we would like to let you know that we have a new bank account for membership
payments in EUR:

  SK20 8330 0000 0026 0150 2873
  BIC: FIOZSKBA
  https://ib.fio.cz/ib/transparent?a=2601502873

The original bank account will continue to work, but please don't use it for
future payments. The new account is denominated in EUR to help us save some
money on conversions to and from CZK.

Best regards,

vpsAdmin @ vpsFree.cz
END

module TransactionChains
  module Maintenance
    remove_const(:Custom)

    class Custom < TransactionChain
      label 'Notify users'

      def link_chain
        ::User.where(object_state: ::User.object_states[:active]).each do |user|
          last_payment = ::UserPayment.where(user: user).where.not(
            incoming_payment: nil,
          ).order('id DESC').take
          next if last_payment.nil?

          ip = last_payment.incoming_payment

          if (ip.src_currency && ip.src_currency.upcase == CURRENCY) \
             || (ip.src_currency.nil? && ip.currency.upcase == CURRENCY)
            puts "Notifying user #{last_payment.user_id} #{last_payment.user.login}"
            mail_custom(
              from: 'podpora@vpsfree.cz',
              user: user,
              role: :account,
              subject: SUBJ[user.language.code.to_sym],
              text_plain: MAIL[user.language.code.to_sym],
              vars: {user: user},
            )
          end
        end
      end
    end
  end
end

TransactionChains::Maintenance::Custom.fire
