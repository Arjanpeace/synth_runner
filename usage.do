* This file shows three examples. Each can be turned off by changing
*  if 1{
* to 
*  if 0{
*  around the appropriate section

* Header
clear all
mac drop _all
log close _all
log using "usage.log", replace
version 12
set scheme s2mono
set more off
mata: mata set matafavor speed
set tracedepth 2
*set trace on


* Re-doing the maing example from -synth-
sysuse smoking, clear
tsset state year

compress
qui describe, varlist
global orig_vars "`r(varlist)'"

if 1{
local tper 1989
* The main example in -help synth- for California with the first post-treatment period being 1989
*For the case of single treated unit, -synth_runner- will generate an output file that's a bit more helpful
tempfile keepfile
synth_runner cigsale beer(1984(1)1988) lnincome(1972(1)1988) retprice age15to24 cigsale(1988) cigsale(1980) cigsale(1975), ///
	trunit(3) trperiod(`tper') keep(`keepfile') 
ereturn list
mat li e(treat_control)

merge 1:1 state year using `keepfile', nogenerate
gen cigsale_synth = cigsale-effect

single_treatment_graphs, depvar(cigsale) trunit(3) trperiod(`tper') ///
	raw_gname(cigsale1_raw) effects_gname(cigsale1_effects) effects_ylabels(-30(10)30) effects_ymax(35) effects_ymin(-35)

effect_graphs , depvar(cigsale) depvar_synth(cigsale_synth) trunit(3) trperiod(`tper') ///
	effect_gname(cigsale1_effect) tc_gname(cigsale1_tc)
	
pval_graphs , pvals_gname(cigsale1_pval) pvals_t_gname(cigsale1_pval_t)
keep $orig_vars
}

** Same treatment, matched a bit differently
if 1{
local tper 1989
gen byte D = (state==3 & year>=`tper')
tempfile keepfile2
synth_runner cigsale beer(1984(1)1988) lnincome(1972(1)1988) retprice age15to24, ///
	trunit(3) trperiod(`tper') trends training_propr(`=13/18') pre_limit_mult(10) keep(`keepfile2')
ereturn list
mat li e(treat_control)
merge 1:1 state year using `keepfile2', nogenerate
gen cigsale_scaled_synth = cigsale_scaled - effect_scaled
gen cigsale_synth        = cigsale        - effect

single_treatment_graphs, depvar(cigsale_scaled) ///
	effect_var(effect_scaled) trunit(3) trperiod(`tper') raw_gname(cigsale2_raw) effects_gname(cigsale2_effects)
effect_graphs , depvar(cigsale_scaled) depvar_synth(cigsale_scaled_synth) ///
	effect_var(effect_scaled) trunit(3) trperiod(`tper') ///
	effect_gname(cigsale2_effect) tc_gname(cigsale2_tc)
pval_graphs , pvals_gname(cigsale2_pval) pvals_t_gname(cigsale2_pval_t)
keep $orig_vars
}

**Now a more complicated example
if 1{
*Make a treatment indicator variable for -synth_runner- rather than listing specifically (which -synth- does)
gen byte D = (state==3 & year>=1989) | (state==7 & year>=1988) //Georgia
synth_runner cigsale beer(1984(1)1987) lnincome(1972(1)1987) retprice age15to24, d(D) ///
	trends training_propr(`=13/18')
ereturn list
mat li e(treat_control)
effect_graphs , multi depvar_lbl(`:variable label cigsale') effect_gname(cigsale3_effect) tc_gname(cigsale3_tc)
pval_graphs , pvals_gname(cigsale3_pval) pvals_t_gname(cigsale3_pval_t)
}

*Save the named graphs to disk
qui graph dir, memory
local grphs "`r(list)'"
foreach gname of local grphs{
	if "`gname'"=="Graph" continue //these are unnamed ones
	qui graph save `gtype' "`gname'.gph", replace
	qui graph export "`gname'.eps", name(`gname') replace
}

cap noisily log close