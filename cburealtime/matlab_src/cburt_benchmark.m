function cburt_benchmark(cburt, seriesnumber)

onr=cburt.benchmarking.series(seriesnumber).onreceived;

global cburealtime_defaults
actions=[strcmp({cburt.actions.protocolname},cburealtime_defaults.protocol.functional.protocolname)];
