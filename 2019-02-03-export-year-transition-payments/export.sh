#!/bin/sh
export RACK_ENV=production

for year in 2016 2017 2018 ; do
	ruby export_year_transition_payments_forward.rb $year > platby_1_${year}_$(($year+1)).csv
done

for year in 2019 2018 2017 ; do
	ruby export_year_transition_payments_backward.rb $year > platby_2_${year}_$(($year-1)).csv
done
