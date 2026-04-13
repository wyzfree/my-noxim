/*
 * ChipIO - Cross-chip IO module for multi-chip Noxim simulation
 *
 * Connects to the boundary routers of all chips and routes flits
 * between chips based on dst_chip_id in the flit header.
 *
 * Port numbering (clockwise from top-left):
 *   [0 .. dimx-1]                        : NORTH edge (y=0)
 *   [dimx .. dimx+dimy-1]                : EAST  edge (x=dimx-1)
 *   [dimx+dimy .. 2*dimx+dimy-1]         : SOUTH edge (y=dimy-1)
 *   [2*dimx+dimy .. 2*dimx+2*dimy-1]     : WEST  edge (x=0)
 */

#ifndef __NOXIM_CHIPIO_H__
#define __NOXIM_CHIPIO_H__

#include <queue>
#include <vector>
#include <string>
#include <fstream>
#include <systemc.h>
#include "NoC.h"
#include "DataStructs.h"
#include "GlobalParams.h"

using namespace std;

struct CrossTrafficEntry {
    int src_chip;
    int dst_chip;
    int src_pe;
    int dst_pe;
    int inject_cycle;
};

SC_MODULE(ChipIO)
{
    sc_in_clk   clock;
    sc_in<bool> reset;

    SC_HAS_PROCESS(ChipIO);

    ChipIO(sc_module_name name, vector<NoC*>& noc_chips);

    // Inject a flit into a specific chip's boundary port
    void manualInject(int chip_id, int port, Flit flit);
    void loadCrossTraffic(const string& filename);

    // Select the nearest boundary port for a given dst PE coordinate
    static int nearestBoundaryPort(int dst_pe);

private:
    vector<CrossTrafficEntry> cross_traffic;
    void crossTrafficThread(); // SC_THREAD: injects at scheduled cycles
    int num_chips;
    int total_ports; // boundary ports per chip = 2*(dimx+dimy)

    // Dynamic port arrays [chip * total_ports + port]
    // IO -> router (inject direction)
    sc_out<Flit>**              flit_in_ports;
    sc_out<bool>**              req_in_ports;
    sc_in<bool>**               ack_in_ports;
    sc_in<TBufferFullStatus>**  buf_status_ports;
    // router -> IO (receive direction)
    sc_in<Flit>**               flit_out_ports;
    sc_in<bool>**               req_out_ports;
    sc_out<bool>**              ack_out_ports;

    // ABP level tracking [chip][port]
    vector<vector<bool>> level_in;
    vector<vector<bool>> level_out;

    // Pending flits to inject: inQueue[chip][port]
    vector<vector<queue<Flit>>> inQueue;

    // Flits received from routers waiting for cross-chip dispatch
    queue<pair<Flit, pair<int,int>>> rxBuffer; // flit, (chip, port)

    void process();
    void txProcess();
    void rxProcess();
    void dispatchCrossChip();

    static void port2Coord(int p, int& x, int& y, int& dir);
    void connectAll(vector<NoC*>& noc_chips);

    // --- ChipIO Statistics ---
public:
    void printStats() const;

private:
    // Per-link TX count: stats_tx[src_chip][dst_chip]
    vector<vector<int>> stats_tx;
    // Per-chip RX count from NoC boundary (flits captured by rxProcess)
    vector<int> stats_rx_from_noc;
    // Cross-chip flit end-to-end latency samples (cycles)
    vector<double> stats_cross_latency;
    // Queue depth samples [chip][port] high-water mark
    vector<vector<int>> stats_queue_hwm;
};

#endif
