#!/bin/bash


OPTIND=1         

# Initialize our own variables:
i_face_1="h2-eth0"
i_face_2="h3-eth0"
n_packets=100
exp_type="butterfly"

while getopts "h?i:j:n" opt; do
    case "$opt" in
    h|\?)
        echo "./run_experiments.sh -i <Interface name for receive stream 1> -j <Interface name for receive stream 2> -n <Number of packets to send> "
        exit 0
        ;;
    i)  i_face_1=$OPTARG
        ;;
    j)  i_face_2=$OPTARG
        ;;
    n)  n_packets=$OPTARG
        ;;
    esac
done

echo "Iface 1: " $i_face_1
echo "Iface 2: " $i_face_2
echo "NPackets: " $n_packets
echo "Experiemt type: " $exp_type

for send_rate in 0.1
do
	for pkt_size in 4096
	do
		echo "Configuration of  next experiment ...."
		echo "Payload size = " $pkt_size

		sudo python experiments/experiment.py --iface1 $i_face_1 --iface2 $i_face_2 --npackets $n_packets --type $exp_type --payload $pkt_size --rate $send_rate --bw 1.0

	done
done