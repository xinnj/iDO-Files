#! /bin/bash

if [ "$#" != "3" ]; then
        echo "Usage: `basename $0` <config> <root folder> <dry run (true|false)>"
    exit 1
fi

config=$1
root_folder=$2
dry_run=$3

IFS=$'\n'
conf=()
while read line; do
    conf+=("$line")
done < $config

sorted_conf=($(sort -dr <<<"${conf[*]}"))

folders=($(find $root_folder -type d -print))

for one_folder in "${folders[@]}"; do
    for one_conf in "${sorted_conf[@]}"; do
        IFS=':'
        one_conf_array=($one_conf)
        if [[ "$one_folder" == "${one_conf_array[0]}"* ]]; then
            cd "$one_folder" || exit 1
            total_num=$(ls -ld * 2>/dev/null |grep -v '^d' | wc -l)
            del_num=$(expr $total_num - ${one_conf_array[1]})

            if [[ $del_num -gt 0 ]]; then
                echo "Clean $one_folder, keep ${one_conf_array[1]} files"
                if $dry_run; then
                    echo "Files to be cleaned: $del_num (dry run)"
                    ls -ltrd * 2>/dev/null | grep -v 'total' |grep -v '^d' | awk '{print $9}' | head -n $del_num
                else
                    echo "Files to be cleaned: $del_num"
                    ls -ltrd * 2>/dev/null | grep -v 'total' |grep -v '^d' | awk '{print $9}' | head -n $del_num | xargs rm -vf
                fi
            fi
            break
        fi
    done
done