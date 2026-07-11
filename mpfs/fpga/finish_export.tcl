# finish_export.tcl -- the ~1hr build succeeded (timing 0/0, prog file generated) but
# export_prog_job failed only because the export dir didn't exist. Just re-export.
set PROJDIR {C:/Users/lkwangsi/Documents/github/sarProcessor/mpfs/fpga/libero_corefft_vm}
open_project -file "$PROJDIR/corefft_vm.prjx"
file mkdir "$PROJDIR/export"
puts "@@@ EXPORTING"
export_prog_job -job_file_name {SAR_TOP_corefft} -export_dir "$PROJDIR/export" -bitstream_file_type {TRUSTED_FACILITY}
puts "@@@ EXPORT_DONE"
