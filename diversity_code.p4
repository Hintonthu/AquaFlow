/* -*- P4_16 -*- */

/*
 * The Protocol header looks like this:
 *
 *        0                1                  2              3
 * +----------------+----------------+----------------+---------------+
 * |      P         |       4        |             Version            |
 * +----------------+----------------+----------------+---------------+
 * |                              Payload                             |
 * +----------------+----------------+----------------+---------------+
 * |                            Coded Payload                         |
 * +----------------+----------------+----------------+---------------+
 *
 * P is an ASCII Letter 'P' (0x50)
 * 4 is an ASCII Letter '4' (0x34)
 * Version is currently 0.1 (0x01)
 */

#include <core.p4>
#include <v1model.p4>

/*
 * Define the headers the program will recognize
 */

/*
 * Standard ethernet header 
 */
header ethernet_t {
    bit<48> dstAddr;
    bit<48> srcAddr;
    bit<16> etherType;
}

#define MAX_HOPS 9

const bit<16> CODING_ETYPE = 0x1234;
const bit<8>  CODING_P     = 0x50;   // 'P'
const bit<8>  CODING_4     = 0x34;   // '4'
const bit<8>  CODING_A     = 0x41;   // 'A'
const bit<8>  CODING_B     = 0x42;   // 'B'
const bit<8>  CODING_X     = 0x58;   // 'X'
const bit<8>  CODING_VER   = 0x01;   // v0.1

const bit<8>  CODING_PACKET_TO_CODE     = 0x01;
const bit<8>  CODING_PACKET_TO_FORWARD  = 0x02;
const bit<8>  CODING_PACKET_TO_DECODE   = 0x03;

const bit<8> DONT_CLONE = 0;
const bit<8> DO_CLONE = 1;
const bit<8> POST_CLONE = 2;

const bit<32> DECODING_BUFFER_SIZE = 128;
const bit<32> INIT_CODED_PACKETS_SEQNUM = 1;

const bit<32> CODING_BATCH_SIZE = 2;

typedef bit<800> payload_t;

header coding_hdr_t {
    bit<8>  p;
    bit<8>  four;
    bit<8>  ver;
    bit<8>  packet_todo;
    bit<8>  packet_contents;
    bit<32>  coded_packets_batch_num;
    payload_t packet_payload;
}


typedef bit<32> switchID_t;
typedef bit<32> qdepth_t;
typedef bit<48> ingress_global_timestamp_t;
typedef bit<32> enq_timestamp_t;
typedef bit<32> deq_timedelta_t;

header stats_hdr_t {
    bit<8> num_switch_stats;
}

header switch_stats_t {
    switchID_t swid;
    ingress_global_timestamp_t igt;
    enq_timestamp_t enqt;
    deq_timedelta_t delt;
}

/*
 * All headers, used in the program needs to be assembed into a single struct.
 * We only need to declare the type, but there is no need to instantiate it,
 * because it is done "by the architecture", i.e. outside of P4 functions
 */
struct headers {
    ethernet_t                  ethernet;
    stats_hdr_t                 stats;
    switch_stats_t[MAX_HOPS]    switch_stats;
    coding_hdr_t                coding;
}

/*
 * All metadata, globally used in the program, also  needs to be assembed 
 * into a single struct. As in the case of the headers, we only need to 
 * declare the type, but there is no need to instantiate it,
 * because it is done "by the architecture", i.e. outside of P4 functions
 */

struct parser_metadata_t {
    bit<8>  remaining;
}

struct intrinsic_metadata_t {
    bit<16> recirculate_flag;
}

struct coding_metadata_t { 
    bit<16> clone_number;
    bit<8>  clone_status;
    bit<32> coded_packets_batch_num;
}

struct decoding_metadata_t {
    bit<8>  is_clone;
}

struct metadata {
    parser_metadata_t       parser_metadata;
    intrinsic_metadata_t    intrinsic_metadata;
    coding_metadata_t       coding_metadata;
    decoding_metadata_t     decoding_metadata;
}


/*************************************************************************
 ***********************  P A R S E R  ***********************************
 *************************************************************************/
parser MyParser(packet_in packet,
                out headers hdr,
                inout metadata meta,
                inout standard_metadata_t standard_metadata) {

    state start {
        packet.extract(hdr.ethernet);
        transition select(hdr.ethernet.etherType) {
            CODING_ETYPE : parse_stats;
            default      : accept;
        }
    }
    
    state parse_stats {
        packet.extract(hdr.stats);
        meta.parser_metadata.remaining = hdr.stats.num_switch_stats;
        transition select(meta.parser_metadata.remaining) {
            0 : check_coding;
            default: parse_switch_stats;
        }
    }

    state parse_switch_stats {
        packet.extract(hdr.switch_stats.next);
        meta.parser_metadata.remaining = meta.parser_metadata.remaining  - 1;
        transition select(meta.parser_metadata.remaining) {
            0 : check_coding;
            default: parse_switch_stats;
        }
    }

    state check_coding {
        transition select(packet.lookahead<coding_hdr_t>().p, packet.lookahead<coding_hdr_t>().four, packet.lookahead<coding_hdr_t>().ver) {
            (CODING_P, CODING_4, CODING_VER) : parse_coding;
            default                          : accept;
        }
    }
    
    state parse_coding {
        packet.extract(hdr.coding);
        transition accept;
    }
}

/*************************************************************************
 ************   C H E C K S U M    V E R I F I C A T I O N   *************
 *************************************************************************/
control MyVerifyChecksum(inout headers hdr,
                         inout metadata meta) {
    apply { }
}

/*************************************************************************
 **************  I N G R E S S   P R O C E S S I N G   *******************
 *************************************************************************/
control MyIngress(inout headers hdr,
                  inout metadata meta,
                  inout standard_metadata_t standard_metadata) {

    register<payload_t>(2) reg_coding_payload_buffer;
    register<bit<32>>(1) reg_num_input_pkts;
    register<bit<32>>(1) reg_coded_packets_batch_num;

    register<payload_t>(DECODING_BUFFER_SIZE) reg_payload_decoding_buffer_a;
    register<payload_t>(DECODING_BUFFER_SIZE) reg_payload_decoding_buffer_b;
    register<payload_t>(DECODING_BUFFER_SIZE) reg_payload_decoding_buffer_x;
    register<bit<32>>(1) reg_a_index;
    register<bit<32>>(1) reg_b_index;
    register<bit<32>>(1) reg_x_index;
    register<bit<32>>(DECODING_BUFFER_SIZE) reg_num_sent_per_index;
    register<bit<32>>(DECODING_BUFFER_SIZE) reg_num_recv_per_index;
    register<bit<32>>(DECODING_BUFFER_SIZE) reg_xor_received_per_index;
    register<bit<32>>(DECODING_BUFFER_SIZE) reg_rcv_seq_num_per_index;

    bit<32> rcv_seq_num_per_index;
    bit<32> this_pkt_index;
    bit<32> a_index;
    bit<32> b_index;
    bit<32> x_index;
    bit<32> num_sent_per_index;
    bit<32> num_recv_per_index;
    bit<32> xor_received_per_index;

    action _nop () { 
    }

    action send_from_ingress(bit<9> egress_port, bit<8> packet_contents, bit<32> packet_coded_packets_batch_num) {
        hdr.coding.coded_packets_batch_num = packet_coded_packets_batch_num;
        hdr.coding.packet_contents = packet_contents;
        standard_metadata.egress_spec = egress_port;
        meta.coding_metadata.clone_status = POST_CLONE;
    }

    action mac_forward_from_ingress(bit<9> egress_port) {
        standard_metadata.egress_spec = egress_port;
    }

    action ingress_index_1 (bit<9> egress_port) {
        reg_coding_payload_buffer.write(1, hdr.coding.packet_payload);
        send_from_ingress(egress_port, CODING_B, meta.coding_metadata.coded_packets_batch_num);
    }

    action ingress_index_2 (bit<9> egress_port) {
        payload_t operand1;
        payload_t operand2;
        reg_coding_payload_buffer.read(operand1, 0);
        reg_coding_payload_buffer.read(operand2, 1);
        hdr.coding.packet_payload = operand1 ^ operand2;
        send_from_ingress(egress_port, CODING_X, meta.coding_metadata.coded_packets_batch_num);
    }

    table table_ingress_code {
        key = {    
               hdr.ethernet.dstAddr: exact;
               meta.coding_metadata.clone_number: exact;
              }

        actions = {_nop; ingress_index_1; ingress_index_2;}
        size = 10;
        default_action = _nop;
    }

    action ingress_cloned_packets_loop () { 
        // This causes the packet to be not cloned at egress 
        meta.coding_metadata.clone_status = DONT_CLONE;
    }

    table table_ingress_clone {
        key = {    
               meta.coding_metadata.clone_number: exact;
              }

        actions = {_nop; ingress_cloned_packets_loop; send_from_ingress;}
        size = 10;
        default_action = _nop;
    }

    table table_mac_fwd {
        key = {
                hdr.ethernet.dstAddr: exact;
              }

        actions = {_nop; mac_forward_from_ingress;}
        size = 10;
        default_action = _nop;
    }

    apply 
    {
        if (hdr.coding.isValid()) {

            //Logic for Coding

            if (hdr.coding.packet_todo == CODING_PACKET_TO_CODE) {

                // If it is not a cloned packet...
                if (meta.coding_metadata.clone_number == 0)
                {
                    bit<32> num_input_pkts;
                    reg_num_input_pkts.read(num_input_pkts, 0);

                    bit<32> curr_coded_packets_batch_num;
                    reg_coded_packets_batch_num.read(curr_coded_packets_batch_num, 0);
                    if (curr_coded_packets_batch_num == 0) {
                        curr_coded_packets_batch_num = INIT_CODED_PACKETS_SEQNUM;
                        reg_coded_packets_batch_num.write(0, curr_coded_packets_batch_num);
                    }

                    // If it is the first of the two packets AND not a cloned packet, send it out
                    if (num_input_pkts == 0)
                    {
                        reg_coding_payload_buffer.write(0, hdr.coding.packet_payload);
                        send_from_ingress(2, CODING_A, curr_coded_packets_batch_num);
                        reg_num_input_pkts.write(0, 1);
                    }

                    // If it is the second of two packets, don't send it out but keep track of it
                    // and clone
                    else if (num_input_pkts == 1)
                    {
                        // Copy the payload for coding later on...
                        reg_num_input_pkts.write(0, 0);

                        // Put the sequence number in the packet metadata so it is maintained
                        meta.coding_metadata.coded_packets_batch_num = curr_coded_packets_batch_num;

                        // Increase the coded sequence number, this happens every two packets
                        reg_coded_packets_batch_num.write(0, curr_coded_packets_batch_num + 1);

                        // Clone
                        meta.coding_metadata.clone_status = DO_CLONE;
                        table_ingress_clone.apply();
                    }
                }
                // If it is a cloned packet, do the coding and then send them out via table_ingress_code
                else if (meta.coding_metadata.clone_number > 0)
                {
                    table_ingress_code.apply();
                }
            }

            //Logic for forwarding
            else if (hdr.coding.packet_todo == CODING_PACKET_TO_FORWARD) {
                //Signal the next switch to decode this packet
                hdr.coding.packet_todo = CODING_PACKET_TO_DECODE;

                table_mac_fwd.apply();
            }

            //Logic for decoding
            else if (hdr.coding.packet_todo == CODING_PACKET_TO_DECODE) {

                this_pkt_index = hdr.coding.coded_packets_batch_num % DECODING_BUFFER_SIZE;

                // Get the number of pkts received for this seq num
                reg_num_recv_per_index.read(num_recv_per_index, this_pkt_index);

                // Get the number of sent out for this seq num
                reg_num_sent_per_index.read(num_sent_per_index, this_pkt_index);

                // Get the status of received packets for this index
                reg_xor_received_per_index.read(xor_received_per_index, this_pkt_index);

                //Get the current occupant seq_num of this index
                reg_rcv_seq_num_per_index.read(rcv_seq_num_per_index, this_pkt_index);

                //If it is zero, then set this current pkt as the occupant
                if (rcv_seq_num_per_index == 0)
                {
                    reg_rcv_seq_num_per_index.write(this_pkt_index, hdr.coding.coded_packets_batch_num);
                }

                if (meta.decoding_metadata.is_clone == 1)  {
                    //fill up the clone with other payload by using the XOR coded payload in buffer
                    payload_t coded_payload;
                    reg_payload_decoding_buffer_x.read(coded_payload, this_pkt_index);
                    hdr.coding.packet_payload = hdr.coding.packet_payload ^ coded_payload;
                    hdr.coding.packet_contents = CODING_X;

                    // Update here
                    reg_num_sent_per_index.write(this_pkt_index, num_sent_per_index + 1);
                    table_mac_fwd.apply();
                }
                else
                if (meta.decoding_metadata.is_clone == 0)
                {
                    // if the sequence number of the packet(s) in the buffer is different than this packet then rollover has occured, reset everything.
                    if (hdr.coding.coded_packets_batch_num != rcv_seq_num_per_index) 
                    {
                        reg_xor_received_per_index.write(this_pkt_index, 0);
                        reg_num_sent_per_index.write(this_pkt_index, 0);
                        reg_num_recv_per_index.write(this_pkt_index, 0);
                        
                        xor_received_per_index = 0;
                        num_sent_per_index = 0;
                        num_recv_per_index = 0;
    
                        // And put the new seq_num in the buffer
                        reg_rcv_seq_num_per_index.write(this_pkt_index, hdr.coding.coded_packets_batch_num);
                    }

                    if (num_sent_per_index < 2)
                    {
                        // Update for all non-cloned packets
                        reg_num_recv_per_index.write(this_pkt_index, num_recv_per_index + 1);

                        // Copy the packet payload in appropriate buffer and update the index
                        if (hdr.coding.packet_contents == CODING_A) {
                            reg_payload_decoding_buffer_a.write(this_pkt_index, hdr.coding.packet_payload);
                            reg_a_index.write(0, this_pkt_index);
                        }
                        else
                        if (hdr.coding.packet_contents == CODING_B) {
                            reg_payload_decoding_buffer_b.write(this_pkt_index, hdr.coding.packet_payload);
                            reg_b_index.write(0, this_pkt_index);
                        }
                        else 
                        if (hdr.coding.packet_contents == CODING_X) {
                            reg_payload_decoding_buffer_x.write(this_pkt_index, hdr.coding.packet_payload);
                            reg_x_index.write(0, this_pkt_index);
                        }

                        reg_a_index.read(a_index, 0);
                        reg_b_index.read(b_index, 0);
                        reg_x_index.read(x_index, 0);

                        // If the packet is A or B
                        if (hdr.coding.packet_contents == CODING_A || hdr.coding.packet_contents == CODING_B) 
                        {
                            // If XOR was already received, then clone/deocde and send this
                            if (xor_received_per_index == 1)
                            {
                                //Clone this packet and send it along
                                meta.decoding_metadata.is_clone = 1;
                                standard_metadata.clone_spec = 450;
                                clone3(CloneType.E2E, standard_metadata.clone_spec, {meta.intrinsic_metadata, meta.decoding_metadata, standard_metadata});

                                // Update here
                                reg_num_sent_per_index.write(this_pkt_index, num_sent_per_index + 1);
                                table_mac_fwd.apply();
                                }
                            else
                            if (xor_received_per_index == 0)
                            {
                                // Update here
                                reg_num_sent_per_index.write(this_pkt_index, num_sent_per_index + 1);
                                table_mac_fwd.apply();
 
                            }
                        }

                        // If the packet is X
                        else if (hdr.coding.packet_contents == CODING_X) {

                            reg_xor_received_per_index.write(this_pkt_index, 1);

                            // If one packet was previously received/sent then decode using XOR
                            if (num_sent_per_index == 1) {
                                // Pickup the uncoded packet and xor it with this one to get the other payload
                                payload_t uncoded_payload;

                                if (a_index >= this_pkt_index) 
                                {
                                    reg_payload_decoding_buffer_a.read(uncoded_payload, this_pkt_index);
                                    payload_t a_payload;
                                    a_payload = hdr.coding.packet_payload ^ uncoded_payload;
                                    hdr.coding.packet_payload = a_payload;
                                }
                                else
                                if (b_index >= this_pkt_index) 
                                {
                                    reg_payload_decoding_buffer_b.read(uncoded_payload, this_pkt_index);
                                    payload_t b_payload;
                                    b_payload = hdr.coding.packet_payload ^ uncoded_payload;
                                    hdr.coding.packet_payload = b_payload;
                                }
                                // Update here
                                reg_num_sent_per_index.write(this_pkt_index, num_sent_per_index + 1);
                                table_mac_fwd.apply();
     
                            } 
                            else 
                            // If XOR was the first packet that arrived, then drop and wait for one of the others
                            if (num_sent_per_index == 0) {
                                mark_to_drop();
                            }
                        } 
                    }   
                    else
                    {
                        // Update for all non-cloned packets
                        reg_num_recv_per_index.write(this_pkt_index, num_recv_per_index + 1);

                    } 

                }
                //mark_to_drop();
            }
        }
        else 
        {
            mark_to_drop();
        }
    }
}

/*************************************************************************
 ****************  E G R E S S   P R O C E S S I N G   *******************
 *************************************************************************/
control MyEgress(inout headers hdr,
                 inout metadata meta,
                 inout standard_metadata_t standard_metadata) {

    action add_switch_stats(switchID_t swid) { 
        hdr.stats.num_switch_stats = hdr.stats.num_switch_stats + 1;
        hdr.switch_stats.push_front(1);
        hdr.switch_stats[0].swid = swid;
        hdr.switch_stats[0].igt = (ingress_global_timestamp_t)standard_metadata.ingress_global_timestamp;
        hdr.switch_stats[0].enqt = (enq_timestamp_t)standard_metadata.enq_timestamp;
        hdr.switch_stats[0].delt = (deq_timedelta_t)standard_metadata.deq_timedelta;
    }

    table switch_stats {
        actions = { 
        add_switch_stats; 
        NoAction; 
        }
        default_action = NoAction();      
    }

    action egress_cloning_step() {
        meta.coding_metadata.clone_number = meta.coding_metadata.clone_number + 1;
        standard_metadata.clone_spec = 250;
        clone3(CloneType.E2E, standard_metadata.clone_spec, {meta.intrinsic_metadata, meta.coding_metadata, standard_metadata});
        recirculate({meta.intrinsic_metadata, meta.coding_metadata, standard_metadata});
    }
    action egress_cloning_stop() {
        mark_to_drop();
    }
    action egress_coded_packets_processing(switchID_t swid) {
        //Signal the next switch to simply forward this packet
        hdr.coding.packet_todo = CODING_PACKET_TO_FORWARD;

        add_switch_stats(swid);
    }

    table table_egress_clone {
        key = {    
               meta.coding_metadata.clone_status: exact;
               meta.coding_metadata.clone_number: exact;
              }
        actions = {egress_cloning_step; egress_cloning_stop; egress_coded_packets_processing;}
        size = 10;
    }

    apply { 
        if (hdr.coding.isValid()) {
            // Logic for coding
            if (hdr.coding.packet_todo == CODING_PACKET_TO_CODE) {
                table_egress_clone.apply();
            }
            // Logic to forward
            else if (hdr.coding.packet_todo == CODING_PACKET_TO_FORWARD) {
                switch_stats.apply();
            }

            // Logic for decoding
            else if (hdr.coding.packet_todo == CODING_PACKET_TO_DECODE) {
                switch_stats.apply();
            }
    
        }
        else {
            mark_to_drop();
        }
    }
}

/*************************************************************************
 *************   C H E C K S U M    C O M P U T A T I O N   **************
 *************************************************************************/

control MyComputeChecksum(inout headers hdr, inout metadata meta) {
    apply { }
}

/*************************************************************************
 ***********************  D E P A R S E R  *******************************
 *************************************************************************/
control MyDeparser(packet_out packet, in headers hdr) {
    apply {
        packet.emit(hdr.ethernet);
        packet.emit(hdr.stats);
        packet.emit(hdr.switch_stats);
        packet.emit(hdr.coding);
    }
}

/*************************************************************************
 ***********************  S W I T T C H **********************************
 *************************************************************************/

V1Switch(
MyParser(),
MyVerifyChecksum(),
MyIngress(),
MyEgress(),
MyComputeChecksum(),
MyDeparser()
) main;
