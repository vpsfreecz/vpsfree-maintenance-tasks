#!/bin/sh

export RACK_ENV=production
YEAR="$1"

if [ "$1" == "" ] ; then
	echo "Usage: $0 <year>"
	exit 1
fi

DIR="export-$(date '+%Y-%m-%d')"

mkdir $DIR

ruby year_transition_forward.rb $(($YEAR-1)) > $DIR/platby_$(($YEAR-1))_${YEAR}.csv
ruby year_within.rb ${YEAR} > $DIR/platby_${YEAR}_${YEAR}.csv
ruby year_transition_backward.rb $(($YEAR+1)) > $DIR/platby_$(($YEAR+1))_${YEAR}.csv

echo $DIR
