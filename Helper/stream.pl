# Loads NookMedia.dylib into this Apple-signed perl so MediaRemote answers, then hands over to it.
use DynaLoader;
my $lib = DynaLoader::dl_load_file($ARGV[0], 0) or die DynaLoader::dl_error();
my $sym = DynaLoader::dl_find_symbol($lib, "nook_run") or die "nook_run missing";
DynaLoader::dl_install_xsub("main::nook_run", $sym);
main::nook_run();
