#!/usr/bin/env python

import sys
import time
import argparse

from scapy.all import bind_layers
from scapy.all import Ether
from scapy.all import sendp

import time

from scapy.all import Packet, XStrFixedLenField, StrFixedLenField, XByteField, IntField

parser = argparse.ArgumentParser(description='send stream')
parser.add_argument('--npackets',dest="npackets", help='n_packets td send',
                    type=int, action="store", required=True)
parser.add_argument('--type', dest="type", help='topology_name',
                    type=str, action="store", default="diversity")
parser.add_argument('--payload', dest="payload", help='payload size',
                    action="store", required=True)

parser.add_argument('--rate', dest="rate", action="store", type=float, default=0.0, help="send rate in bits per sec")

args = parser.parse_args()

num_pkts = int(args.npackets)
args.type = args.type
payload_size = int(args.payload)


class CodingHdrS(Packet):
    global payload_size
    fields_desc = [
                    XByteField("num_switch_stats", 0x01),
                    StrFixedLenField("P", "P", length=1),
                    StrFixedLenField("Four", "4", length=1),
                    XByteField("version", 0x01),
                    XByteField("packet_todo", 0x01),
                    StrFixedLenField("packet_contents", ' ', length=1),
                    IntField("coded_packets_batch_num", 0),
                    StrFixedLenField("packet_payload", ' '*(payload_size/8), length=payload_size/8)]


bind_layers(Ether, CodingHdrS, type=0x1234)


def main():

    iface = 'h1-eth0'
    
    dst_mac = None

    global payload_size, args, num_pkts

    if payload_size <= 0 :
        payload_size = 1

    if args.type == "butterfly" or args.type == "butterfly_forwarding":
        dst_mac = "01:0C:CD:01:00:00"
    elif args.type == "diversity":
        dst_mac = "00:00:00:00:05:02"
    else:
        print "Incorrect experiment type"
        sys.exit(0)


    if args.type == "diversity" :

        pktA = Ether(dst=dst_mac, type=0x1234) / CodingHdrS(num_switch_stats=0, packet_contents='A', packet_payload="A" * (payload_size/8))
        pktA = pktA/' '

        pktB = Ether(dst=dst_mac, type=0x1234) / CodingHdrS(num_switch_stats=0, packet_contents='B', packet_payload="B" * (payload_size/8))
        pktB = pktB/' '

        time.sleep(2)

        for i in range(num_pkts/2):
            sendp(pktA, iface=iface)
            sendp(pktB, iface=iface)

    else:
        n_bits = 2*payload_size
        if args.rate == 0.0 :
            time_to_sleep = 0.0
        else:
            rate = float(args.rate)*1000000.0
            time_to_sleep = float(n_bits)/float(rate)

            print "Time to sleep (secs) = ", time_to_sleep


        
        for i in range(num_pkts/2):

            curr_time = str(time.time())
            n_chars = (payload_size/8)

            payload_A = "A"
            payload_B = "B"

            n_chars_left = n_chars - 1 - len(curr_time)

            payload_A = payload_A + ("0"* n_chars_left)
            payload_B = payload_B + ("0"* n_chars_left)

            payload_A = payload_A + curr_time
            payload_B = payload_B + curr_time

            pktA = Ether(dst=dst_mac, type=0x1234) / CodingHdrS(num_switch_stats=0, packet_contents='A', packet_payload=payload_A)
            pktA = pktA/' '

            pktB = Ether(dst=dst_mac, type=0x1234) / CodingHdrS(num_switch_stats=0, packet_contents='B', packet_payload=payload_B)
            pktB = pktB/' '


            sendp(pktA, iface=iface)
            sendp(pktB, iface=iface)

            if(time_to_sleep > 0)
                time.sleep(float(time_to_sleep))




if __name__ == '__main__':
    main()
