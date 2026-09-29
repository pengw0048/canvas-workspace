#!/bin/zsh
# Creates the trip demo fixtures: scripts/demo/japan/make-fixtures.sh <dir>  (PYTHON may point at a venv with openpyxl and python-docx)
set -e
d=$1; here=${0:A:h}; mkdir -p $d
cp $here/booking.html $d/
swift $here/ticket.swift "$d/新幹線きっぷ.pdf"
${PYTHON:-python3} $here/office.py $d
echo "fixtures in $d"
