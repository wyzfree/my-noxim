/*
 * Noxim - the NoC Simulator
 *
 * (C) 2005-2018 by the University of Catania
 * For the complete list of authors refer to file ../doc/AUTHORS.txt
 * For the license applied to these sources refer to file ../doc/LICENSE.txt
 *
 * This file contains the implementation of the top-level of Noxim
 */

#include "ConfigurationManager.h"
#include "NoC.h"
#include "GlobalStats.h"
#include "DataStructs.h"
#include "GlobalParams.h"
#include "ChipIO.h"

#include <csignal>
#include <vector>

using namespace std;

// need to be globally visible to allow "-volume" simulation stop
unsigned int drained_volume;
NoC **chips;

void signalHandler( int signum )
{
    cout << "\b\b  " << endl;
    cout << endl;
    cout << "Current Statistics:" << endl;
    cout << "(" << sc_time_stamp().to_double() / GlobalParams::clock_period_ps << " sim cycles executed)" << endl;
    for (int c = 0; c < GlobalParams::num_chips; c++) {
        cout << "--- Chip " << c << " ---" << endl;
        GlobalStats gs(chips[c]);
        gs.showStats(std::cout, GlobalParams::detailed);
    }
}

int sc_main(int arg_num, char *arg_vet[])
{
    signal(SIGQUIT, signalHandler);

    // TEMP
    drained_volume = 0;

    // Handle command-line arguments
    cout << "\t--------------------------------------------" << endl;
    cout << "\t\tNoxim - the NoC Simulator" << endl;
    cout << "\t\t(C) University of Catania" << endl;
    cout << "\t--------------------------------------------" << endl;

    cout << endl;
    cout << endl;

    configure(arg_num, arg_vet);

    cout << "Number of chips: " << GlobalParams::num_chips << endl;

    // Signals
    sc_clock clock("clock", GlobalParams::clock_period_ps, SC_PS);
    sc_signal <bool> reset;

    // Instantiate all chips
    vector<NoC*> chip_vec(GlobalParams::num_chips);
    chips = new NoC*[GlobalParams::num_chips];
    for (int c = 0; c < GlobalParams::num_chips; c++) {
        char name[32];
        sprintf(name, "Chip_%d", c);
        chips[c] = new NoC(name);
        chips[c]->clock(clock);
        chips[c]->reset(reset);
        chip_vec[c] = chips[c];
    }

    // Instantiate ChipIO for cross-chip flit routing
    ChipIO* chip_io = new ChipIO("ChipIO", chip_vec);
    chip_io->clock(clock);
    chip_io->reset(reset);

    // Reset all chips and run the simulation
    reset.write(1);
    cout << "Reset for " << (int)(GlobalParams::reset_time) << " cycles... ";
    srand(GlobalParams::rnd_generator_seed);

    sc_start(GlobalParams::reset_time * GlobalParams::clock_period_ps, SC_PS);

    reset.write(0);
    cout << " done! " << endl;
    cout << " Now running for " << GlobalParams::simulation_time << " cycles..." << endl;

    sc_start(GlobalParams::simulation_time * GlobalParams::clock_period_ps, SC_PS);

    // Close the simulation
    cout << "Noxim simulation completed.";
    cout << " (" << sc_time_stamp().to_double() / GlobalParams::clock_period_ps << " cycles executed)" << endl;
    cout << endl;

    // Show statistics for each chip
    for (int c = 0; c < GlobalParams::num_chips; c++) {
        cout << "========== Chip " << c << " ==========" << endl;
        GlobalStats gs(chips[c]);
        gs.showStats(std::cout, GlobalParams::detailed);
    }

    // Show ChipIO cross-chip statistics
    if (GlobalParams::num_chips > 1)
        chip_io->printStats();

    if ((GlobalParams::max_volume_to_be_drained > 0) &&
	(sc_time_stamp().to_double() / GlobalParams::clock_period_ps - GlobalParams::reset_time >=
	 GlobalParams::simulation_time)) {
	cout << endl
             << "WARNING! the number of flits specified with -volume option" << endl
	     << "has not been reached. ( " << drained_volume << " instead of " << GlobalParams::max_volume_to_be_drained << " )" << endl
             << "You might want to try an higher value of simulation cycles" << endl
	     << "using -sim option." << endl;
    }

#ifdef DEADLOCK_AVOIDANCE
	cout << "***** WARNING: DEADLOCK_AVOIDANCE ENABLED!" << endl;
#endif
    return 0;
}
