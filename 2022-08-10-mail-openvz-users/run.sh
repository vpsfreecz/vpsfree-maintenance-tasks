#!/usr/bin/env bash
sent_list=$(pwd)/sent_list.txt

touch $sent_list
chown vpsadmin-api:vpsadmin-api $sent_list

exec ./mail_openvz_users.rb $sent_list
