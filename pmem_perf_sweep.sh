#!/bin/bash
# This script uses MLC to measure bandwidth and latency for Intel® Optane™ Persistent Memory
# memory using App Direct mode.
# It will try to auomatically detect the number of PMEM mapped
# to the specified pmem mount path (should be socket 0)
# Before running this, you need to make a filesystem on the namespace and
# mount it as dax
# example:
#   sudo mkfs.ext4 -b 4096 -E stride=512 -F /dev/pmem
#   sudo mount -o dax /dev/pmem /mnt/pmem
# See help output for list of optional arguments
pushd $PWD &> /dev/null

#################################################################################################
# useful parameters to edit
#################################################################################################

MLC=./mlc                                       # default, -m option to override
PMEM_PATH=/mnt/pmem	                      			# default, -p option to override
BUF_SZ=400000					                          # used in MLC perthread files
SLOTS_PER_CHANNEL=2
OUTPUT_PATH="./outputs.`date +"%m%d-%H%M"`"     # created by the script
INPUT_FILE="/tmp/input"                         # MLC input file
SWEEP_LOG="core_sweep"
CORE_COUNT_FILE="optimal_cores.txt"
SAMPLE_TIME=30                                  # -t argument to MLC
SWEEP_TIME=5
socket=0					# -s argument default socket
AVX512=1
BANDWIDTH="F"
IDLE="F"
LOADED="F"
ITERATIONS=1

# Index these by number of DIMMS to get optimal thread count for the address pattern
#                     0  1  2  3  4  5  6  7  8

# injection delays used for loaded latency (to vary demand bitrate)
DELAYS=(0 50 100 200 300 400 500 700 850 1000 1150 1300 1500 1700 2500 3500 5000 20000 40000 80000)

#################################################################################################
# helper functions
#################################################################################################

trap ctrl_c INT
function ctrl_c() {
   echo "Got contr+c - aborting"
   popd &> /dev/null
   exit 2
}

function display_help() {
   echo "Usage: $0 [optional args] [test flags]"
   echo "Runs bandwidth and latency tests on PMEM backed PMEM memory using MLC"
   echo "Run with root privilege (MLC needs it)"
   echo "Optional args:"
   echo "   -m <Path to MLC executable>"
   echo "      By default, The MLC binary is expected to be in $MLC"
   echo "   -p <Path to mounted PMEM directory>"
   echo "      By default, The pmem memory is expected to be mounted to $PMEM_PATH"
   echo "   -s <Socket>"
   echo "      By default, Socket 0 is used for load the traffic"
   echo "   -a <Specify whether to enable or disable the AVX_512 option>"
   echo "      1: AVX_512 Option Enabled 0: AVX_512 Option Disabled"
   echo "      By default, the AVX_512 option is enabled. If the non-AVX512"
   echo "      version of MLC is being used, this option shall be set to 0"
   echo "   -n <Number of iterations>"
   echo "      By default, the number of iterations is 1"
   echo "Test flags:"
   echo "By default, if no flag is specified it will run the 3 tests: bandwidth, loaded latency and idle latency"
   echo "   -b | -bw"
   echo "      Run only bandwidth test"
   echo "   -i | -id"
   echo "      Run only idle latency test"
   echo "   -l | -ld"
   echo "      Run only loaded latency test"
   exit 3
}

function handle_args() {
  if [ "$1" = "--h" ] || [ "$1" = "-help" ] || [ "$1" = "--help" ] || [ "$1" = "help" ]; then
    display_help $0
  fi

  if [[ $EUID -ne 0 ]]; then
    echo "Please run this script with root privilege"
    exit 1
  fi

  while getopts "h?m:p:s:bbwiidlln:" opt; do
    case "$opt" in
    h|\?)
      display_help $0
      ;;
    m)    MLC=$OPTARG
      ;;
    p)    PMEM_PATH=$OPTARG
      ;;
    s)    socket=$OPTARG
      ;;
    a)    AVX512=$OPTARG
      ;;
    b|bw) BANDWIDTH="T";
      ;;
    i|id) IDLE="T";
      ;;
    l|ld) LOADED="T";
      ;;
    n)    ITERATIONS=$OPTARG
      ;;
    esac
  done

  if [ "${BANDWIDTH}" == "F" ] && [ "${IDLE}" == "F" ] && [ "${LOADED}" == "F" ]; then
    BANDWIDTH="T"; IDLE="T"; LOADED="T"
  fi

  echo "Using pmem memory mounted to:     $PMEM_PATH"
  echo "Using MLC command:                $MLC"
  echo "Using MLC AVX512 Opt:             $AVX512"
  if [ ! -f $MLC ]; then
    echo "Couldn't find MLC at the indicated location"
    display_help $0
  fi
  TOKENS=( $($MLC --version 2>&1 | head -n 1) )
  MLC_VER=${TOKENS[5]}
  echo "MLC version:                      $MLC_VER"
  if [[ ! "${MLC_VER//v}" =~ [0-9] ]] || (( $(echo  "${MLC_VER//v} < 3.9" | bc -l) )); then
    echo "MLC version not supported. Please use MLC version >= 3.9"
    echo "Exiting."
    exit 0
  fi
  echo "MLC output files stored in:       $OUTPUT_PATH"

  if mountpoint -q -- "$PMEM_PATH"; then
    DAX_SUPPORT=$(mount | grep -w $PMEM_PATH | grep dax | wc -l)
    if (($DAX_SUPPORT <= 0)); then
      echo "Mounted filesystem doesn't support DAX"
      display_help $0
    fi
    TOKENS=( $(mount | grep -w $PMEM_PATH) )
    FS_TYPE=${TOKENS[4]}
    echo "Mount found, FS type:             $FS_TYPE"
  else
    echo "Couldn't find pmem mounted at the path in this script"
    echo "If you haven't already, create a dax supporting filesystem on the namespace and mount it"
    display_help $0
  fi

  echo -n "Kernel version:                   "
  uname -r
}

function handle_config() {
  # Get total count of channels in the system
  TOTAL_MEMORY_SLOTS=$(dmidecode -t memory | grep 'Bank Locator: NODE' |  awk '{ print } END { print NR }' | tail -1)
  #Get channels per socket
  MEMORY_CHANNELS_PER_SOCKET=$((TOTAL_MEMORY_SLOTS/(SOCKETS_IN_SYSTEM*SLOTS_PER_CHANNEL)))
  #load core counts
  DIMMS_SIZE=($(ipmctl show -a -dimm | grep -w "Capacity" | cut -d'=' -f 2 | awk '{ print $1}'))
  #validate all DIMMs are same size
  for i in $(seq 0 $(($NUM_DIMMS-1))); do
    if [ "${DIMMS_SIZE[0]}" != "${DIMMS_SIZE[$i]}" ]; then
      echo "PMEM are not same capacity. Please use only PMEM of same capacity"
      exit 0;
    fi
  done
  DIMM_SIZE=${DIMMS_SIZE[NUM_DIMMS*socket]}
  if (( $(bc <<< "${DIMM_SIZE} > 116") )) && (( $(bc <<< "${DIMM_SIZE} < 128") )); then
    DIMM_TYPE="SDP"
    DIMM_SIZE_GB="128GB"
  elif (( $(bc <<< "${DIMM_SIZE} > 245") )) && (( $(bc <<< "${DIMM_SIZE} < 256") )); then
    DIMM_TYPE="DDP"
    DIMM_SIZE_GB="256GB"
  elif (( $(bc <<< "${DIMM_SIZE} > 500") )) && (( $(bc <<< "${DIMM_SIZE} < 512") )); then
    DIMM_TYPE="QDP"
    DIMM_SIZE_GB="512GB"
  else
    echo "DIMM capacity not supported"
    exit 0;
  fi

  DIMMS_POWER_BUDGET=($(ipmctl show -a -dimm | grep "AvgPower" | cut -d'=' -f 2 | awk '{ print $1}'))
  #validate all DIMMs are in same power budget
  for i in $(seq 0 $(($NUM_DIMMS-1))); do
    if [ "${DIMMS_POWER_BUDGET[0]}" != "${DIMMS_POWER_BUDGET[$i]}" ]; then
      echo "PMEM are not in same power budget. Please use same power budget for all PMEM"
      exit 0;
    fi
  done
  DIMM_POWER_BUDGET=${DIMMS_POWER_BUDGET[0]}
  if (( ${DIMM_POWER_BUDGET} > 9500 )) && (( ${DIMM_POWER_BUDGET} < 11500 )); then
    DIMM_POWER="10W"
  elif (( ${DIMM_POWER_BUDGET} > 11501 )) && (( ${DIMM_POWER_BUDGET} < 14500 )); then
    DIMM_POWER="12W"
  elif (( ${DIMM_POWER_BUDGET} > 14501 )) && (( ${DIMM_POWER_BUDGET} < 17500 )); then
    DIMM_POWER="15W"
  elif (( ${DIMM_POWER_BUDGET} > 17501 )) && (( ${DIMM_POWER_BUDGET} < 21000 )); then
    DIMM_POWER="18W"
  else
    echo "DIMM power budget not supported"
  fi
}

function init_outputs() {
  rm -rf $OUTPUT_PATH 2> /dev/null
  mkdir $OUTPUT_PATH

  DELAYS_FILE=$OUTPUT_PATH/delays.txt
  for DELAY in "${DELAYS[@]}"; do 
    echo $DELAY >> $DELAYS_FILE
  done
  DRAM_PERTHREAD=$OUTPUT_PATH/DRAM_perthread.txt
  PMEM_PERTHREAD=$OUTPUT_PATH/PMEM_perthread.txt
  INPUT_FILE=/t
}

function check_cpus() {
  TOKENS=( $(lscpu | grep "Core(s) per socket:") )
  CORES_PER_SOCKET=${TOKENS[3]}
  # only using the CPUs on this NUMA node
  CPUS=$CORES_PER_SOCKET
  echo "CPUs detected:                    $CPUS"
  # One CPU used to measure latency, so the rest can be for bandwidth generation
  BW_CPUS=$(($CPUS-1))
}

function check_rage_per_socket(){
   SOCKETS_IN_SYSTEM=$( lscpu | grep "Socket(s):" | awk '{print $2}' )
   if (( $socket >= $SOCKETS_IN_SYSTEM )); then
      echo "There is no socket ${socket} in the system."
      exit 0
   fi

   FIRST_P=$((${CORES_PER_SOCKET} * ${socket}))
   END_P=$(((${CORES_PER_SOCKET} * (${socket} + 1) - 1)))
   RANGE="${FIRST_P}-${END_P}"
   echo "Range of Socket $socket:  		  $RANGE"
}


function get_optimal_cores(){
  echo ""
  echo -n "Finding optimal thread count for the measurements. This might take a while, please be patient.  "
  CORESWEEP_ARRAY=(
  #  Traffic type   seq or rand  buffer size   pmem or dram     pmem path
    "R              seq          $BUF_SZ       pmem           $PMEM_PATH           END_RD_SEQ_CPUS"
    "R              rand         $BUF_SZ       pmem           $PMEM_PATH           END_RD_RND_CPUS"
    "W6             seq          $BUF_SZ       pmem           $PMEM_PATH           END_WR_SEQ_CPUS"
    "W6             rand         $BUF_SZ       pmem           $PMEM_PATH           END_WR_RND_CPUS"
    "W7             seq          $BUF_SZ       pmem           $PMEM_PATH           END_MX_SEQ_CPUS"
    "W7             rand         $BUF_SZ       pmem           $PMEM_PATH           END_MX_RND_CPUS"
   )

  for LN in "${CORESWEEP_ARRAY[@]}"; do
    TOK=( $LN )
    MAX_CORES=0
    MAX_BW=0
    END_CORE=0
    while [[ "$END_CORE" -le "$((CORES_PER_SOCKET - 1))" ]]; do
      echo "${FIRST_P}-$((FIRST_P + END_CORE))  ${TOK[0]} seq ${TOK[2]} ${TOK[3]}  ${TOK[4]}" > $INPUT_FILE
      if [ ${TOK[0]} == "R" ]; then SFENCE=""; else SFENCE="-Q"; fi
      if [ ${TOK[1]} == "rand" ]; then RAND="-l256"; else RAND=""; fi
      $MLC --loaded_latency -d0 -o$INPUT_FILE -t$SWEEP_TIME -T -Z $RAND $SFENCE >> $OUTPUT_PATH/${SWEEP_LOG}_${TOK[0]}_${TOK[1]}.txt
      BW=$(tail -n 4 $OUTPUT_PATH/${SWEEP_LOG}_${TOK[0]}_${TOK[1]}.txt | grep '0\.00' | awk '{print $3}')
      if (( $(echo "$BW > $MAX_BW" | bc -l)  )); then
        MAX_BW=$BW
        MAX_CORES=$(( END_CORE ))
      fi
      END_CORE=$(( END_CORE + 1 ))
    done
    eval "${TOK[5]}=$(( MAX_CORES + 1 ))" 
    sleep 1
  done
}


function check_dimms() {
  # Find the number of PMEM in the namespace
  NUM_DIMMS=0
  # Check FW version if we can with ipmctl
  command -v ipmctl &> /dev/null
  IPMCTL_NOT_PRESENT=$?
  if (($IPMCTL_NOT_PRESENT == 0)); then
    echo "PMEM DIMM size:                   $DIMM_TYPE - $DIMM_SIZE_GB"
    echo "DIMM power limit:                 $DIMM_POWER"
    echo "Management software version:"
    ipmctl version
    echo "PMEM Firmware versions:"
    ipmctl show -firmware -dimm
  else
    echo "ipmctl not found, cannot use it to detect PMEM FW version"
  fi

  # First try with ndctl as we can follow the namespace to the DIMMs
  command -v ndctl &> /dev/null
  NDCTL_NOT_PRESENT=$?
  if (($NDCTL_NOT_PRESENT == 0)); then
    echo -n "NDCTL version:                "
    ndctl -v
    DEV_PATH=$(mount | grep -w $PMEM_PATH | awk '{print $1;}')
    if [[ $DEV_PATH == /dev/pmem* ]]; then
      DEV=$(echo $DEV_PATH | cut -c10-)
      NUM_DIMMS=$(ndctl list -DR -r $DEV | grep '"dimm":"' | wc -l)
    else
      echo "Don't understand dev path $DEV_PATH"
    fi
  else
    echo "ndctl not found, cannot use it to detect number of DIMMS"
  fi

  if (($NUM_DIMMS <= 0)); then
    # Assuming namespace is on socket 0, so just looking at DIMMS there
    if (($IPMCTL_NOT_PRESENT == 0)); then
      echo "as secondary approach to PMEM count detection, using ipmctl"
      echo "ASSUMING NAMESPACE IS ON SOCKET 0!"
      NUM_DIMMS=$(ipmctl show -topology | grep "Logical Non-Volatile Device" | grep CPU${socket} | wc -l)
    else
      echo "ipmctl not found, cannot use it to detect number of DIMMS"
    fi
  fi

  # if still 0, ask the caller
  if (($NUM_DIMMS <= 0)); then
    echo "Unable to automatically determine the number of DIMMS in the namespace"
    echo -n "please enter the PMEM count: "
    read NUM_DIMMS
    if (($NUM_DIMMS < 1 )); then
      echo "Cannot have < 1 PMEM in the namespace, exiting"
      exit 1
    fi
    if (($NUM_DIMMS >  $MEMORY_CHANNELS_PER_SOCKET )); then
      echo "Cannot have >  $MEMORY_CHANNELS_PER_SOCKET PMEM in the namespace, exiting"
      exit 1
    fi
  fi
  echo "PMEM count in namespace:      $NUM_DIMMS"
}


function fix_ranges(){
  # Calculate how many threads to use for each traffic type
  END_RD_SEQ_CPUS=$((($END_RD_SEQ_CPUS + $FIRST_P) - 1))
  if (($END_RD_SEQ_CPUS > $END_P));then
  END_RD_SEQ_CPUS=$END_P
  fi
  END_RD_RND_CPUS=$((($END_RD_RND_CPUS + $FIRST_P) - 1))
  if (($END_RD_RND_CPUS > $END_P));then
    END_RD_RND_CPUS=$END_P
  fi
  END_WR_SEQ_CPUS=$((($END_WR_SEQ_CPUS + $FIRST_P) - 1))
  if (($END_WR_SEQ_CPUS > $END_P));then
    END_WR_SEQ_CPUS=$END_P
  fi
  END_WR_RND_CPUS=$((($END_WR_RND_CPUS + $FIRST_P) - 1))
  if (($END_WR_RND_CPUS > $END_P));then
    END_WR_RND_CPUS=$END_P
  fi
  END_MX_SEQ_CPUS=$((($END_MX_SEQ_CPUS + $FIRST_P) - 1))
  if (($END_MX_SEQ_CPUS > $END_P));then
    END_MX_SEQ_CPUS=$END_P
  fi
  END_MX_RND_CPUS=$((($END_MX_RND_CPUS + $FIRST_P) - 1))
  if (($END_MX_RND_CPUS > $END_P));then
    END_MX_RND_CPUS=$END_P
  fi
  RANGE_RD_SEQ_CPUS="$FIRST_P-$END_RD_SEQ_CPUS"
  RANGE_RD_RND_CPUS="$FIRST_P-$END_RD_RND_CPUS"
  RANGE_WR_SEQ_CPUS="$FIRST_P-$END_WR_SEQ_CPUS"
  RANGE_WR_RND_CPUS="$FIRST_P-$END_WR_RND_CPUS"
  RANGE_MX_SEQ_CPUS="$FIRST_P-$END_MX_SEQ_CPUS"
  RANGE_MX_RND_CPUS="$FIRST_P-$END_MX_RND_CPUS"

  END_RD_SEQ_CPUS="$(($END_RD_SEQ_CPUS - ($CPUS * ${socket}) + 1))"
  END_RD_RND_CPUS="$(($END_RD_RND_CPUS - ($CPUS * ${socket}) + 1))"
  END_WR_SEQ_CPUS="$(($END_WR_SEQ_CPUS - ($CPUS * ${socket}) + 1))"
  END_WR_RND_CPUS="$(($END_WR_RND_CPUS - ($CPUS * ${socket}) + 1))"
  END_MX_SEQ_CPUS="$(($END_MX_SEQ_CPUS - ($CPUS * ${socket}) + 1))"
  END_MX_RND_CPUS="$(($END_MX_RND_CPUS - ($CPUS * ${socket}) + 1))"


}

#################################################################################################
# Metric measuring functions
#################################################################################################

function idle_latency() {
  LAT_CORE=$(echo $RANGE_RD_SEQ_CPUS | cut -d- -f1)
  echo ""
  echo -n "PMEM idle sequential latency: "
  $MLC --idle_latency -J$PMEM_PATH -c${LAT_CORE}> $OUTPUT_PATH/idle_seq.txt
  cat $OUTPUT_PATH/idle_seq.txt | grep "Each iteration took" 
  echo -n "PMEM idle random     latency: "
  $MLC --idle_latency -l256 -J$PMEM_PATH -c${LAT_CORE} > $OUTPUT_PATH/idle_rnd.txt
  cat $OUTPUT_PATH/idle_rnd.txt | grep "Each iteration took"
}

function bandwidth() {
  #if socket = 0 then X = 0, if socket = 1 then X = CPUs
  echo ""
  echo "PMEM bandwidth: using $END_RD_SEQ_CPUS for sequential read, $END_RD_RND_CPUS for random read,"
  echo "                       $END_WR_SEQ_CPUS for sequential write, $END_WR_RND_CPUS for random write,"
  echo "                       $END_MX_SEQ_CPUS for sequential mixed, $END_MX_RND_CPUS for random mixed."
  BW_ARRAY=(
  #  CPUs            Traffic type   seq or rand  buffer size   pmem or dram   pmem path     output filename
    "$RANGE_RD_SEQ_CPUS R              seq          $BUF_SZ       pmem           $PMEM_PATH    bw_seq_READ_${END_RD_SEQ_CPUS}.txt"
    "$RANGE_RD_RND_CPUS R              rand         $BUF_SZ       pmem           $PMEM_PATH    bw_rnd_READ_${END_RD_RND_CPUS}.txt"
    "$RANGE_WR_SEQ_CPUS W6             seq          $BUF_SZ       pmem           $PMEM_PATH    bw_seq_WRNT_${END_WR_SEQ_CPUS}.txt"
    "$RANGE_WR_RND_CPUS W6             rand         $BUF_SZ       pmem           $PMEM_PATH    bw_rnd_WRNT_${END_WR_RND_CPUS}.txt"
    "$RANGE_MX_SEQ_CPUS W7             seq          $BUF_SZ       pmem           $PMEM_PATH    bw_seq_21NT_${END_MX_SEQ_CPUS}.txt"
    "$RANGE_MX_RND_CPUS W7             rand         $BUF_SZ       pmem           $PMEM_PATH    bw_rnd_21NT_${END_MX_RND_CPUS}.txt"
  )
  for LN in "${BW_ARRAY[@]}"; do
    TOK=( $LN )
    echo ${TOK[0]} ${TOK[1]} seq ${TOK[3]} ${TOK[4]} ${TOK[5]} > $PMEM_PERTHREAD
    echo -n "max PMEM bandwidth for ${TOK[6]} - Delay, nS, MBPS: "
    if [ ${TOK[1]} == "R" ]; then
      SFENCE=""
    else
      SFENCE="-Q"
    fi
    if [ ${TOK[2]} == "rand" ]; then
      RAND="-l256"
    else
	    RAND=""
	  fi
    $MLC --loaded_latency -d0 -o$PMEM_PERTHREAD -t$SAMPLE_TIME -T -Z $RAND $SFENCE > $OUTPUT_PATH/${TOK[6]}
    cat $OUTPUT_PATH/${TOK[6]} | sed -n -e '/==========================/,$p' | tail -n+2
    sleep 3
  done
}

function loaded_latency() {
  LAT_CORE=$(echo $RANGE_RD_SEQ_CPUS | cut -d- -f1)
  FIRST_CORE=$(($LAT_CORE + 1))
  LAST_CORE=$(echo $RANGE_RD_SEQ_CPUS | cut -d- -f2)
  if [[ $(( $LAST_CORE + 1 )) -lt $END_P ]]; then LAST_CORE=$(($LAST_CORE + 1)); fi
  RANGE_RD_SEQ_CPUS="${FIRST_CORE}-${LAST_CORE}"
  echo ""
  echo "$LAT_CORE  R seq  $BUF_SZ pmem $PMEM_PATH" >  $PMEM_PERTHREAD
  echo "$RANGE_RD_SEQ_CPUS R seq  $BUF_SZ pmem $PMEM_PATH" >> $PMEM_PERTHREAD
  echo ${END_RD_SEQ_CPUS} core PMEM sequential read loaded latency sweep:
  echo " Delay nS         MBPS"
  $MLC --loaded_latency -g$DELAYS_FILE -o$PMEM_PERTHREAD -t$SAMPLE_TIME -Z -c$LAT_CORE > $OUTPUT_PATH/out_llat_seq_READ_$RD_SEQ_CPUS.txt
  cat $OUTPUT_PATH/out_llat_seq_READ_$RD_SEQ_CPUS.txt | sed -n -e '/==========================/,$p' | tail -n+2

  LAT_CORE=$(echo $RANGE_RD_RND_CPUS | cut -d- -f1)
  FIRST_CORE=$(($LAT_CORE + 1))
  LAST_CORE=$(echo $RANGE_RD_RND_CPUS | cut -d- -f2)
  if [[ $(( $LAST_CORE + 1 )) -lt $END_P ]]; then LAST_CORE=$(($LAST_CORE + 1)); fi
  RANGE_RD_RND_CPUS="${FIRST_CORE}-${LAST_CORE}"
  echo "$LAT_CORE  R seq $BUF_SZ pmem $PMEM_PATH" >  $PMEM_PERTHREAD
  echo "$RANGE_RD_RND_CPUS R rand $BUF_SZ pmem $PMEM_PATH" >> $PMEM_PERTHREAD
  echo ${END_RD_RND_CPUS} core PMEM random read loaded latency sweep:
  echo " Delay nS         MBPS"
  $MLC --loaded_latency -g$DELAYS_FILE -o$PMEM_PERTHREAD -t$SAMPLE_TIME -l256 -Z -c$LAT_CORE > $OUTPUT_PATH/out_llat_rnd_READ_$RD_RND_CPUS.txt
  cat $OUTPUT_PATH/out_llat_rnd_READ_$RD_RND_CPUS.txt | sed -n -e '/==========================/,$p' | tail -n+2
}

function start_measurements(){
  if [ ${ITERATIONS} -eq 1 ]; then
    idle_latency
    bandwidth
    loaded_latency
  else
    RESULTS_PATH=$OUTPUT_PATH
    for i in $(seq 1 ${ITERATIONS}); do
      OUTPUT_PATH=${RESULTS_PATH}/Iteration${i}
      mkdir -p $OUTPUT_PATH
      idle_latency
      bandwidth
      loaded_latency
    done
  fi
}

function collect_logs(){
  LOGS_PATH=$OUTPUT_PATH/
  mkdir -p $LOGS_PATH
  echo "Collecting DCPMM and System info logs..."
  ndctl list -vvv > $LOGS_PATH/ndctl-list.log
  ipmctl show -a -dimm > $LOGS_PATH/ipmctl-show-dimm.log
  dmidecode > $LOGS_PATH/dmidecode.log
  mount > $LOGS_PATH/mount.log
  echo "Logs directory: ${LOGS_PATH}"
  echo "Please attach log directory if you need to report any measurement"
}

#################################################################################################
# Main program flow
#################################################################################################

echo "======================================================================="
echo "Starting PMEM bandwidth and latency measurements using MLC" 
echo "======================================================================="

handle_args $@
check_cpus
check_rage_per_socket
handle_config
check_dimms
init_outputs
get_optimal_cores
echo ""
echo "Optimal thread count found. Starting PMEM measurements."
fix_ranges
start_measurements
collect_logs

echo "======================================================================="
echo "PMEM bandwidth and latency measurements Complete"
echo "======================================================================="

popd &> /dev/null
exit 0
