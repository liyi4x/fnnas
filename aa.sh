#!/bin/bash

model_conf=/home/ly/code/fnnas/make-fnnas/fnnas-files/common-files/etc/model_database.conf
make_board=elfboard-elf2



error_msg() {
    echo -e " [💔] ${1}"
    exit 1
}

process_msg() {
    echo -e " [🌿] ${1}"
}



clean_model_conf() {
    [[ -f "${model_conf}" ]] || return 1
    sed -e 's/NA//g' -e 's/NULL//g' -e 's/[ ][ ]*//g' "${model_conf}" | grep -E '^[^#].+'
}


check_data() {
    # Columns of ${model_conf}:
    # 1.ID  2.MODEL  3.SOC  4.FDTFILE  5.UBOOT_OVERLOAD  6.MAINLINE_UBOOT  7.BOOTLOADER_IMG  8.DESCRIPTION
    # 9.KERNEL_TAGS  10.PLATFORM  11.FAMILY  12.BOOT_CONF  13.CONTRIBUTORS  14.BOARD  15.BUILD
    [[ -f "${model_conf}" ]] || error_msg "Missing model configuration file: [ ${model_conf} ]"

    # Get a list of build devices
    if [[ "${make_board}" == "all" ]]; then
        board_list=":(yes)"
        make_fnnas=($(
            clean_model_conf |
                grep -E "^.*:yes$" | awk -F':' '{print $14}' |
                sort -u | xargs
        ))
    elif [[ "${make_board}" =~ ^(amlogic|rockchip|allwinner)([0-9]+_[0-9]+|[0-9]+)?$ ]]; then
        # Get the platform name and range, such as [ amlogic50 ], [ rockchip50_100 ], etc.
        # name is [ amlogic ], [ rockchip ], [ allwinner ], range is [ 50 ], [ 50_100 ], etc.
        # amlogic50 -> platform_name=amlogic, platform_range=50, rockchip50_100 -> platform_name=rockchip, platform_range=50_100
        platform_name="${BASH_REMATCH[1]}"
        platform_range="${BASH_REMATCH[2]}"
        make_fnnas=($(
            clean_model_conf |
                grep -E "^.*:${platform_name}:.*:yes$" | awk -F':' '{print $14}' |
                sort -u | xargs
        ))
        # Slice by range if specified, such as [ amlogic50 ], [ rockchip50_100 ], etc.
        if [[ "${platform_range}" =~ ^([0-9]+)_([0-9]+)$ ]]; then
            make_fnnas=("${make_fnnas[@]:${BASH_REMATCH[1]}:$((BASH_REMATCH[2] - BASH_REMATCH[1]))}")
        elif [[ -n "${platform_range}" ]]; then
            make_fnnas=("${make_fnnas[@]:0:${platform_range}}")
        fi
        board_list=":($(echo ${make_fnnas[@]} | sed -e 's/ /\|/g')):(yes)"
    elif [[ "${make_board}" =~ ^(first|last)([0-9]+)$ ]]; then
        # first<N>: first N boards, last<N>: last N boards
        slice_type="${BASH_REMATCH[1]}"
        slice_num="${BASH_REMATCH[2]}"
        make_fnnas=($(
            clean_model_conf |
                grep -E "^.*:yes$" | awk -F':' '{print $14}' |
                sort -u | xargs
        ))
        [[ "${slice_type}" == "first" ]] && make_fnnas=("${make_fnnas[@]:0:${slice_num}}")
        [[ "${slice_type}" == "last" ]] && make_fnnas=("${make_fnnas[@]: -${slice_num}}")
        board_list=":($(echo ${make_fnnas[@]} | sed -e 's/ /\|/g')):(yes)"
    elif [[ "${make_board}" =~ ^range([0-9]+)_([0-9]+)$ ]]; then
        # range<N>_<M>: boards from index N, count M-N
        range_start="${BASH_REMATCH[1]}"
        range_end="${BASH_REMATCH[2]}"
        make_fnnas=($(
            clean_model_conf |
                grep -E "^.*:yes$" | awk -F':' '{print $14}' |
                sort -u | xargs
        ))
        make_fnnas=("${make_fnnas[@]:${range_start}:$((range_end - range_start))}")
        board_list=":($(echo ${make_fnnas[@]} | sed -e 's/ /\|/g')):(yes)"
    else
        echo "12312312"
        board_list=":($(echo ${make_board} | sed -e 's/_/\|/g')):(yes|no)"
        # Deduplicate while preserving order so [ -b s905x_s905x ] doesn't build twice.
        make_fnnas=($(echo ${make_board} | tr '_' '\n' | awk 'NF && !seen[$0]++'))
    fi
    [[ "${#make_fnnas[@]}" -eq 0 ]] && error_msg "The [ BOARD ] is missing, stop making."

    process_msg "board_list=${board_list}"
    # Get the kernel array from the model configuration file
    kernel_from=($(
        clean_model_conf |
            grep -E "^.*${board_list}$" | awk -F':' '{print $9}' |
            sort -u | xargs
    ))
    [[ "${#kernel_from[@]}" -eq 0 ]] && error_msg "Missing [ KERNEL_TAGS ] settings, stop building."

    process_msg "kernel_from=${kernel_from}"


    return 0



    # Convert the kernel_from to the kernel array
    for item in "${kernel_from[@]}"; do
        # Split the key and value
        IFS='/' read -r key value <<<"${item}"

        # Check if the value is "all".
        if [[ "${value}" == "all" ]]; then
            # If the value is "all", assign the value of ${key}_kernel. such as [ amlogic_kernel, rockchip_kernel, etc. ]
            eval "value=\"\${${key}_kernel[@]}\""
        elif [[ "${value}" =~ ^[1-9]+ ]]; then
            IFS='_' read -ra value <<<"${value}"
            value="${value[@]}"
        fi

        # If auto_kernel is false, use the value from -k parameter
        if [[ ! "${auto_kernel}" =~ ^(true|yes)$ ]]; then
            if [[ "${#specific_kernel[@]}" -eq 0 ]]; then
                error_msg "Plase use the -k parameter to specify the kernel version."
            else
                value="${specific_kernel[@]}"
            fi
        fi

        # Merge the same key values
        if [[ -n "${tags_list[${key}]}" ]]; then
            tags_list[${key}]+=" ${value}"
        else
            tags_list[${key}]="${value}"
        fi
    done

    # Convert the tags_list array to the kernel array (remove duplicates)
    for key in "${!tags_list[@]}"; do
        # Convert the space-separated string to an array and remove duplicates
        read -ra unique_values <<<"$(echo "${tags_list[${key}]}" | tr ' ' '\n' | sort -u | tr '\n' ' ')"
        # Assign the unique values back to the tags_list
        tags_list[${key}]="${unique_values[@]}"
    done

    # Check the kernel tags list
    [[ "${#tags_list[@]}" -eq 0 ]] && error_msg "The [ tags_list ] is missing, stop building."
    echo -e "${INFO} The kernel tags list: [ ${!tags_list[@]} ]"

    # Convert kernel repository address to api format
    [[ "${kernel_repo}" =~ ^https: ]] && kernel_repo="$(echo ${kernel_repo} | awk -F'/' '{print $4"/"$5}')"
    kernel_api="https://github.com/${kernel_repo}"
}


check_data
