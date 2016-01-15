*! version 1.0 Brian Quistorff <bquistorff@gmail.com>
*! Automates the process of conducting many synthetic control estimations
* Todo: 
* test max_lead. Note CGNP13 define lead1 as contemporaneous (rather than lead0)
* don't overwrite those mata variables (though I do warn)
program synth_runner, eclass
	version 12 //haven't tested on earlier versions
	syntax anything, [D(string) ci pvals1s TREnds training_propr(real 0) max_lead(numlist min=1 max=1 int)  ///
		Keep(string) REPlace TRPeriod(numlist min=1 max=1 int) TRUnit(numlist min=1 max=1 int) pre_limit_mult(string) ///
		COUnit(string) FIGure resultsperiod(string) *]
	gettoken depvar cov_predictors : anything
	get_returns pvar=r(panelvar) tvar=r(timevar) : tsset, noquery
	_assert "`d'`trperiod'`trunit'"!="", msg("Must specify treatment units and time periods (d() or trperiod() and trunit())")
	_assert "`d'"=="" | "`trperiod'`trunit'"=="" , msg("Can't specify both d() and {trperiod(), trunit()}")
	if "`d'"==""{
		tempvar D
		gen byte `D' = (`pvar'==`trunit' & `tvar'>=`trperiod')
	}
	else local D "`d'"
	_assert "`counit'"=="", msg("counit() option not allowed. Non-treated units are assumed to be controls. Remove units that are neither controls nor treatments before invoking.")
	_assert "`figure'"=="", msg("figure option not allowed.")
	_assert "`resultsperiod'"=="", msg("resultsperiod() option not allowed. Use max_lead()")
	if "`pre_limit_mult'"=="" local pre_limit_mult .
	
	tempvar ever_treated tper_var0 tper_var lead event max_lead_per_unit min_lead_per_unit
	tempname trs uniq_trs pvals pvals_t estimates CI pval_pre_RMSPE pval_val_RMSPE ///
		tr_pre_rmspes tr_val_rmspes do_pre_rmspes do_val_rmspes p1 p2 tr_post_rmspes ///
		do_post_rmspes pval_post_RMSPE pval_post_RMSPE_t disp_mat out_ef
	tempfile ind_file agg_file out_e
		
	qui bys `pvar': egen `tper_var0' = min(`tvar') if `D'
	qui bys `pvar': egen `tper_var' = max(`tper_var0')
	*Get a list of repeated treatment dates
	preserve
	qui keep if !mi(`tper_var')
	collapse (first) `tper_var', by(`pvar')
	mkmat `pvar' `tper_var', matrix(`trs')
	contract `tper_var'
	mkmat `tper_var' _freq, matrix(`uniq_trs')
	local num_tpers = rowsof(`uniq_trs')
	restore
	if `num_tpers'>1{
		_assert "`keep'"=="", msg("Can only keep if one period in which units receive treatment")
	}
	cleanup_mata , num_tpers(`num_tpers') warn
	
	qui gen `lead' = `tvar' - `tper_var'+1 
	if "`max_lead'"==""{
		qui bys `pvar': egen `max_lead_per_unit' = max(`lead')
		qui summ `max_lead_per_unit', meanonly
		local max_lead = r(min) //max lead with common support
	}
	qui bys `pvar': egen `min_lead_per_unit' = min(`lead')
	qui summ `min_lead_per_unit', meanonly
	local min_lead = r(max) //min lead with common support
	
	forval lead=1/`max_lead'{
		local leadlist "`leadlist' lead`lead'"
	}
	forval lead=`min_lead'/-1{
		local lag = -1*`lead'
		local laglist "`laglist' lag`lag'"
	}
	local llist "`laglist' lead0 `leadlist'"
	
	bys `pvar': egen byte `ever_treated'=max(`D')
	
	qui levelsof `pvar', local(units)
	qui levelsof `pvar' if `ever_treated'==1, local(tr_units)
	
	di "Estimating the treatment effects"
	local num_tr_units : list sizeof tr_units
	mat `tr_pre_rmspes' = J(`num_tr_units',1,.)
	mat `tr_post_rmspes' = J(`num_tr_units',1,.)
	mat `tr_val_rmspes' = J(`num_tr_units',1,.)
	forval g=1/`num_tr_units'{
		if `num_tr_units'>5  _print_dots `g' `num_tr_units'
		local tr_unit = `trs'[`g',1]
		local tper    = `trs'[`g',2]
		gen_time_locals , tper(`tper') prop(`training_propr') depvar(`depvar') ///
			outcome_pred_loc(outcome_pred) ntraining_loc(ntraining) nvalidation_loc(nvalidation)
		preserve
		qui drop if `ever_treated' & `pvar'!=`tr_unit'
		qui synth_wrapper `depvar' `outcome_pred' `cov_predictors', `options' ///
			trunit(`tr_unit') trperiod(`tper') keep(`ind_file') replace `trends'
		mat `tr_pre_rmspes'[`g',1] = e(pre_rmspe)
		mat `tr_post_rmspes'[`g',1] = e(post_rmspe)
		if `training_propr'>0{
			calc_RMSPE , i_start(`=`ntraining'+1') i_end(`=`ntraining'+`nvalidation'') local(val_rmspe)
			mat `tr_val_rmspes'[`g',1] = `val_rmspe'
		}
		add_keepfile_to_agg, keep(`ind_file') aggfile(`agg_file') tper_var(`tper_var') ///
			tper(`tper') unit(`tr_unit') depvar(`depvar') pre_rmspe(`=`tr_pre_rmspes'[`g',1]') post_rmspe(`=`tr_post_rmspes'[`g',1]')
		restore
	}
	cleanup_and_convert_to_diffs, dta(`agg_file') out_effect(`out_e') min_lead(`min_lead') out_effect_full(`out_ef') max_lead(`max_lead') depvar(`depvar') `trends' tper_var(`tper_var')
	if "`keep'"!="" qui copy `agg_file' `keep', `replace'
	load_dta_to_mata, dta(`out_e') mata_var(tr_effects)
	mata: tr_effect_avg = mean(tr_effects)
	mata: st_matrix("`estimates'", tr_effect_avg)
	mat colnames `estimates' = `leadlist'
	mat rownames `estimates' = `D'
	mata: tr_pre_rmspes = st_matrix("`tr_pre_rmspes'")
	mata: tr_t_effect_avg = mean(tr_effects :/ (tr_pre_rmspes*J(1,`max_lead',1)))
	mata: tr_post_rmspes = st_matrix("`tr_post_rmspes'")
	mata: tr_post_rmspes_t_avg = mean(tr_post_rmspes :/ tr_pre_rmspes)
	
	
	di "Estimating the possible placebo effects"
	local do_units : list units - tr_units
	local num_do_units : list sizeof do_units
	mata: do_effects_p = J(`num_tr_units',1,NULL)
	mata: do_t_effects_p = J(`num_tr_units',1,NULL)
	mata: do_pre_rmspes_p  = J(`num_tr_units',1,NULL)
	mata: do_post_rmspes_p  = J(`num_tr_units',1,NULL)
	mata: do_post_rmspes_t_p  = J(`num_tr_units',1,NULL)
	mata: do_val_rmspes_p  = J(`num_tr_units',1,NULL)
	
	preserve
	qui drop if `ever_treated'
	local do_aggs_i 1
	*Be smart about not redoing matches at the same time.
	local rep 1
	local nloops = cond(`pre_limit_mult'==., `num_tpers',`num_tr_units')
	local num_reps = `nloops'*`num_do_units'
	forval i=1/`nloops'{
		if `pre_limit_mult'==.{
			local tper = `uniq_trs'[`i',1]
			local times =`uniq_trs'[`i',2]
		}
		else {
			local tper = `trs'[`i',2]
			local times = 1
			local pre_rmspe_max = `pre_limit_mult'*`tr_pre_rmspes'[`i',1]
		}
		gen_time_locals , tper(`tper') prop(`training_propr') depvar(`depvar') ///
			outcome_pred_loc(outcome_pred) ntraining_loc(ntraining) nvalidation_loc(nvalidation)
		
		mat `do_pre_rmspes' = J(`num_do_units',1,.)
		mat `do_post_rmspes' = J(`num_do_units',1,.)
		mat `do_val_rmspes' = J(`num_do_units',1,.)
		
		cap erase `agg_file'
		foreach unit of local do_units{
			_print_dots `rep++' `num_reps'
			local j : list posof "`unit'" in do_units
			qui synth_wrapper `depvar' `outcome_pred' `cov_predictors', `options' ///
				trunit(`unit') trperiod(`tper') keep(`ind_file') replace `trends'
			mat `do_pre_rmspes'[`j',1] = e(pre_rmspe)
			mat `do_post_rmspes'[`j',1] = e(post_rmspe)
			if `training_propr'>0{
				calc_RMSPE , i_start(`=`ntraining'+1') i_end(`=`ntraining'+`nvalidation'') local(val_rmspe)
				mat `do_val_rmspes'[`j',1] = `val_rmspe'
			}
			add_keepfile_to_agg, keep(`ind_file') aggfile(`agg_file') tper_var(`tper_var') ///
				tper(`tper') unit(`unit') depvar(`depvar') pre_rmspe(`=`do_pre_rmspes'[`j',1]') post_rmspe(`=`do_post_rmspes'[`j',1]')
		}
		
		cleanup_and_convert_to_diffs, dta(`agg_file') out_effect(`out_e') depvar(`depvar') tper_var(`tper_var') `trends' max_lead(`max_lead') pre_rmspe_max(`pre_rmspe_max')
		load_dta_to_mata, dta(`out_e') mata_var(do_effect_base`i')
		mata: do_pre_rmspe_base`i' = st_matrix("`do_pre_rmspes'")
		mata: do_t_effect_base`i' = do_effect_base`i' :/ (do_pre_rmspe_base`i'*J(1,`max_lead',1))
		mata: do_post_rmspe_base`i' = st_matrix("`do_post_rmspes'")
		mata: do_post_rmspe_t_base`i' = do_post_rmspe_base`i' :/ do_pre_rmspe_base`i'
		if `training_propr'>0 mata: do_val_rmspe_base`i' = st_matrix("`do_val_rmspes'")
		forval j=1/`times'{
			mata: do_effects_p[`do_aggs_i',1]    = &do_effect_base`i'
			mata: do_pre_rmspes_p[`do_aggs_i',1] = &do_pre_rmspe_base`i'
			mata: do_t_effects_p[`do_aggs_i',1]  = &do_t_effect_base`i'
			mata: do_post_rmspes_p[`do_aggs_i',1]= &do_post_rmspe_base`i'
			mata: do_post_rmspes_t_p[`do_aggs_i',1]= &do_post_rmspe_t_base`i'
			if `training_propr'>0 mata: do_val_rmspes_p[`do_aggs_i',1] = &do_val_rmspe_base`i'
			local ++do_aggs_i
		}
	}
	if "`keep'"!=""{
		qui use `keep', clear
		qui append using `agg_file'
		qui save `keep', replace
	}
	restore
	
	di "Conducting inference."
	*Raw Estimates
	mata: do_effect_avgs = get_all_avgs(do_effects_p)
	mata: st_matrix("`pvals'", get_p_vals(tr_effect_avg, do_effect_avgs))
	mat colnames `pvals' = `leadlist'
	if "`ci'"!=""{
		mata: st_matrix("`CI'", get_CIs(tr_effect_avg, do_effect_avgs, strtoreal(st_global("S_level"))))
		mat rownames `CI' = ll ul
		mat colnames `CI' = `leadlist'
	}
	mata: do_post_rmspe_avgs = get_all_avgs(do_post_rmspes_p)
	mata: st_numscalar("`pval_post_RMSPE'", get_p_vals(mean(tr_post_rmspes), do_post_rmspe_avgs)[1,1])
	
	*Pseudo t-stas
	mata: st_matrix("`pvals_t'", get_p_vals(tr_t_effect_avg, get_all_avgs(do_t_effects_p)))
	mat colnames `pvals_t' = `leadlist'
	mata: st_numscalar("`pval_post_RMSPE_t'", get_p_vals(tr_post_rmspes_t_avg, get_all_avgs(do_post_rmspes_t_p))[1,1])
	
	*Diagnostics
	mata: do_pre_rmspe_avgs = get_all_avgs(do_pre_rmspes_p)
	mata: st_numscalar("`pval_pre_RMSPE'", get_p_vals(mean(tr_pre_rmspes), do_pre_rmspe_avgs)[1,1])
	*Validation period RMSPE
	if `training_propr'>0{
		mata: st_numscalar("`pval_val_RMSPE'", get_p_vals(mean(st_matrix("`tr_val_rmspes'")), get_all_avgs(do_val_rmspes_p))[1,1])
	}
	
	*Post output
	di "Post-treatment results: Effects, p-values, p-values (psuedo t-stats)"
	mat `disp_mat' = (`estimates'', `pvals'[2,1...]',`pvals_t'[2,1...]')
	mat colnames `disp_mat' = estimates pvals pvals_tstat
	mat rownames `disp_mat' = `leadlist'
	mat li `disp_mat'
	*Effects
	ereturn post `estimates'
	*Could return avg_post_rmspe, avg_post_rmspe_t, estimates_t but these aren't very interpretable
	matrix rownames `out_ef' = `llist'
	ereturn matrix treat_control = `out_ef'
	
	*Inference stats
	mat `p2' = `pvals'[2,1...]
	mat rownames `p2' = `D'
	ereturn matrix pvals = `p2'
	if "`ci'"!="" ereturn matrix ci = `CI'
	mat `p2' = `pvals_t'[2,1...]
	mat rownames `p2' = `D'
	ereturn matrix pvals_t = `p2'
	if "`pvals1s'"!=""{
		mat `p1' = `pvals'[1,1...]
		mat rownames `p1' = `D'
		ereturn matrix pvals_1s = `p1'
		mat `p1' = `pvals_t'[1,1...]
		mat rownames `p1' = `D'
		ereturn matrix pvals_t_1s = `p1'
	}
	ereturn scalar pval_joint_post = `pval_post_RMSPE'
	ereturn scalar pval_joint_post_t = `pval_post_RMSPE_t'
	
	*Diagnostics stats
	ereturn scalar avg_pre_rmspe_p = `pval_pre_RMSPE'
	if `training_propr'>0{
		ereturn scalar avg_val_rmspe_p = `pval_val_RMSPE'
	}
	
	cleanup_mata, num_tpers(`num_tpers')
end

program cleanup_mata
	syntax , num_tpers(int) [ warn]

	local plain_mata_objs = "do_effect_avgs tr_pre_rmspes tr_post_rmspes do_post_rmspes_t_p " + ///
		"tr_t_effect_avg do_pre_rmspes_p do_effects_p do_pre_rmspe_avgs tr_effect_avg " + ///
		"do_val_rmspes_p tr_effects do_t_effects_p do_post_rmspes_p do_post_rmspe_avgs tr_post_rmspes_t_avg"
	foreach mata_obj of local plain_mata_objs{
		mata: st_local("found", st_local("found")+(rows(direxternal("`mata_obj'"))?"yes":""))
		mata: rmexternal("`mata_obj'")
	}
	
	local per_tper_mata_objs "do_post_rmspe_t_base do_effect_base do_t_effect_base do_pre_rmspe_base do_post_rmspe_base do_val_rmspe_base"
	forval i=1/`num_tpers'{
		foreach mata_obj of local per_tper_mata_objs{
			mata: st_local("found", st_local("found")+(rows(direxternal("`mata_obj'`i'"))?"yes":""))
			mata: rmexternal("`mata_obj'`i'")
		}
	}
	if "`warn'"!="" & "`found'"!="" di as err "-synth_runner- will destroy mata objects: `plain_mata_objs', and numbered `per_tper_mata_objs'"
end



program gen_time_locals
	syntax , tper(int) prop(real) depvar(string) outcome_pred_loc(string) ntraining_loc(string) nvalidation_loc(string)
	get_returns timevar=r(timevar) tmin=r(tmin) : qui tsset

	if `prop'==0 exit
	local ntraining = `tper'-`tmin'
	local nvalidation= 0
	if(`prop'<1){
		_assert `tper'-`tmin'>=2, msg("If training_propr<1 then need at least 2 periods pre-treatment for every treated unit")
		local ntraining = clip(1,int(`prop'*`ntraining'),`ntraining'-1)
		local nvalidation = `tper'-`tmin'-`ntraining'
	}
	forval i=1/`ntraining'{
		local olist = "`olist' `depvar'(`=`tmin'+`i'-1')"
	}
	c_local `outcome_pred_loc' = "`olist'"
	c_local `ntraining_loc' = `ntraining'
	c_local `nvalidation_loc' = `nvalidation'
end

*Simple program to load a numeric dta into a mata variable
program load_dta_to_mata
	syntax, dta(string) mata_var(string)
	
	preserve
	qui use `dta', clear
	mata: `mata_var'=st_data(.,.)
end

*takes a synth keep() file and makes it into "effects" diffs (or pseudo t-stats)
* standardizes lengths and then makes wide.
program cleanup_and_convert_to_diffs
	syntax, dta(string) out_effect(string) depvar(string) tper_var(string) max_lead(int) [out_effect_full(string) trends min_lead(int -1) pre_rmspe_max(string)] 
	get_returns pvar=r(panelvar) tvar=r(timevar) : tsset, noquery
	if "`pre_rmspe_max'"=="" local pre_rmspe_max .
	preserve
	
	keep `depvar' `pvar' `tvar'
	qui merge 1:1 `pvar' `tvar' using `dta', keep(match using) nogenerate
	gen long lead = `tvar'-`tper_var'+1
	gen effect = `depvar'-`depvar'_synth
	if "`trends'"!=""{
		gen effect_scaled = `depvar'_scaled-`depvar'_scaled_synth
	}
	
	if "`out_effect_full'"!=""{
		tempfile int
		qui save `int'
		if "`trends'"!=""{
			qui replace `depvar'       = `depvar'_scaled
			qui replace `depvar'_synth = `depvar'_scaled_synth
		}
		qui drop if lead > `max_lead' | lead < `min_lead'
		collapse (mean) `depvar' `depvar'_synth, by(lead)
		sort lead
		mkmat `depvar' `depvar'_synth, matrix(`out_effect_full')
		qui use `int', clear
	}
	
	drop `depvar' `tper_var' `depvar'*_synth //will have already, redundant, redundant
	qui compress
	qui save `dta', replace
	
	if `pre_rmspe_max'!=. drop if pre_rmspe>`pre_rmspe_max'
	
	if "`trends'"!=""{ //now the main effect is the scaled one
		drop effect
		rename effect_scaled effect
	}
	drop `tvar'
	keep `pvar' lead effect
	qui drop if lead > `max_lead' | lead < 1 /*`min_lead'*/ //for now just deal in post-periods (would have to rework to split matrices)
	qui reshape wide effect, i(`pvar') j(lead)
	drop `pvar' //for now don't need
	qui compress
	qui save `out_effect', replace
end

*Compiles up the keep() files from synth
program add_keepfile_to_agg
	syntax , keep(string) aggfile(string) depvar(string) tper_var(string) tper(int) unit(int) pre_rmspe(real) post_rmspe(real)
	get_returns pvar=r(panelvar) tvar=r(timevar) : tsset, noquery
	preserve
	
	qui use `keep', clear
	drop _Co_Number _W_Weight
	qui drop if mi(_time) //other stuff in the file that might make it longer
	rename _time `tvar'
	rename _Y_treated* `depvar'*
	rename _Y_synthetic* `depvar'*_synth
	drop `depvar' //they have it wherever we merge into
	
	//note the "event" details
	gen long `pvar' = `unit'
	gen long `tper_var'=`tper'
	gen pre_rmspe = `pre_rmspe'
	gen post_rmspe = `post_rmspe'

	cap append using `aggfile'
	qui save `aggfile', replace
end



* will store into locals the return values from command (some commands should 1-liners!)
program get_returns
	gettoken my_opts 0: 0, parse(":")
	gettoken colon their_cmd: 0, parse(":")
	
	`their_cmd'
	foreach my_opt of local my_opts{
		if regexm("`my_opt'","(.+)=(.+\(.+\))"){
			c_local `=regexs(1)' = "``=regexs(2)''"
		}
	}
end

program _print_dots
    version 12
	args curr end
	
	if `c(noisily)'==0 exit 0 //only have one timer going at at time.
	
	local timernum 13
	if "$PRINTDOTS_WIDTH"=="" local width 50
	else local width = clip(${PRINTDOTS_WIDTH},1,50)
	
	*See if passed in both
	if "`end'"==""{
		local end `curr'
		if "$PRINTDOTS_CURR"=="" global PRINTDOTS_CURR 0
		global PRINTDOTS_CURR = $PRINTDOTS_CURR+1
		local curr $PRINTDOTS_CURR
	}
	
	if `curr'==1 {
		timer off `timernum'
		timer clear `timernum'
		timer on `timernum'
		exit 0
	}
	local start_point = min(5, `end')
	if `curr'<`start_point' {
		timer off `timernum'
		qui timer list  `timernum'
		local used `r(t`timernum')'
		timer on `timernum'
		if `used'>60 {
			local remaining = `used'*(`end'/`curr'-1)
			_format_time `= round(`remaining')', local(remaining_toprint)
			_format_time `= round(`used')', local(used_toprint)
			display "After `=`curr'-1': `used_toprint' elapsed, `remaining_toprint' est. remaining"
		}
		exit 0
	}
	if `curr'==`start_point' {
		timer off `timernum'
		qui timer list  `timernum'
		local used `r(t`timernum')'
		timer on `timernum'
		local remaining = `used'*(`end'/`curr'-1)
		_format_time `= round(`remaining')', local(remaining_toprint)
		_format_time `= round(`used')', local(used_toprint)
		display "After `=`curr'-1': `used_toprint' elapsed, `remaining_toprint' est. remaining"
		
		if `end'<`width'{
			di "|" _column(`end') "|" _continue
		}
		else{
			local full_header "----+--- 1 ---+--- 2 ---+--- 3 ---+--- 4 ---+--- 5"
			local header = substr("`full_header'",1,`width')
			di "`header'" _continue
		}
		di " Total: `end'"
		forval i=1/`start_point'{
			di "." _continue
		}
		exit 0
	}
	
	if (mod(`curr', `width')==0 | `curr'==`end'){
		timer off `timernum'
		qui timer list  `timernum'
		local used `r(t`timernum')'
		_format_time `= round(`used')', local(used_toprint)
		if `end'>`curr'{
			timer on `timernum'
			local remaining = `used'*(`end'/`curr'-1)
			_format_time `= round(`remaining')', local(remaining_toprint)
			display ". `used_toprint' elapsed. `remaining_toprint' remaining"
		}
		else{
			di "| `used_toprint' elapsed. "
		}
	}
	else{
		di "." _continue
	}
end

program _format_time
	syntax anything(name=time), local(string)
	
	local suff "s"
	if `time'>100{
		local time=`time'/60
		local suff "m"
		if `time'>100{
			local time = `time'/60
			local suff "h"
			if `time'>36{
				local time = `time'/24
				local suff "d"
			}
		}
	}
	local str =string(`time', "%9.2f")
	c_local `local' `str'`suff'
end

mata:

//ADH10 add 1 to the numerator and denominator of p-value fractions. (CGNP13 do not.)
//It depends on whether you (do|do not) you think the actual test is one of 
// the possible randomizations (usually with bootstraps you add one to the denominator).
real matrix get_p_vals(real rowvector tr_avg, real matrix do_avgs){
	T1 = cols(tr_avg)
	N_PL = rows(do_avgs)

	pvals_s = J(2,T1,.)
	for(t=1; t<=T1; t++){
		if(sign(tr_avg[1,t])>0)
			pvals_s[1,t] = sum(    tr_avg[1,t] :<=    do_avgs[.,t] )/N_PL
		else
			pvals_s[1,t] = sum(    tr_avg[1,t] :>=    do_avgs[.,t] )/N_PL
		
		pvals_s[2,t] =   sum(abs(tr_avg[1,t]):<=abs(do_avgs[.,t]))/N_PL //more common approach
		//pvals_s[2,t] = pvals_s[1,t]:*2 //Ficher 2-sided p-vals
	}
	return(pvals_s)
	
}

//Calculate the 2-sided Confidence Intervals
/* 
	
	* Note that if 0 not in [low_effect,high_effct]
	* then the Confidence Interval won't contain the estimated beta.
	* This is likely with only a few permutation tests.
	
	 * Testing non-null hypotheses of alpha0!=0: 
 * 		Apply null hypothesis (get "unexpected deviation") then permuate.
 * 		In this case, compare (alpha_hat-b0) to {alpha_perm}
 * This means that we take the level-bounds of the null then "flip it around bhat"
 * To make the math a bit nicer, I will reject a hypothesis if pval<=alpha
 * CI: Find all alpha0 that aren't rejected
 *		pval(alpha_hat=alpha0)>alpha
	
 */
real matrix get_CIs(real rowvector tr_avg, real matrix do_avgs, real scalar level){
	T1 = cols(tr_avg)
	N_PL = rows(do_avgs)
	CIs = J(2,T1,.)
	//We might not have enough precision to get alpha, so figure out what we can get
	alpha = (100-level)/100
	p2min = 2/N_PL
	alpha_ind = max((1,round(alpha/p2min)))
	alpha = alpha_ind * p2min
	//Find the CIs
	for(t=1;t<=T1; t++){
		sorted = sort(do_avgs[.,t],1)
		low_effect = sorted[alpha_ind]
		high_effect = sorted[(N_PL+1)-alpha_ind]
		CIs[.,t] = (tr_avg[1,t] - high_effect\ tr_avg[1,t] - low_effect) 
		//note that the "swap" (high_effect used to define lower bound)
	}
	return(CIs)
	//could return alpha too
}

real matrix get_all_avgs(pointer colvector do_aggs){
	G = rows(do_aggs)
	T1 = cols(*do_aggs[1])
	do_picks = ( J(G-1,1,1)\ 0 )
	
	avg_set = J(G   , T1,.)
	tops = J(G, 1, .)
	N_PL = 1
	for(g=1; g<=G; g++){
		J_g = rows(*do_aggs[g])
		tops[g,1] = J_g
		N_PL = N_PL*J_g
	}
	do_avgs = J(N_PL, T1,.)
	for(i=1; i<=N_PL; i++){
		do_picks = inc_index(do_picks, tops) //could pick randomly if sampling (when full N_PL too big)
		
		for(g=1; g<=G; g++){
			avg_set[g,.] = (*do_aggs[g,1])[do_picks[g,1],.]
		}
		do_avgs[i,.] = mean(avg_set)
	}
	return(do_avgs)
}

real colvector inc_index(real colvector picks, real colvector tops){
	G = rows(picks)
	for(g=G; g>=1; g--){
		picks[g,1] = picks[g,1]+1
		if(picks[g,1]<=tops[g])
			break
		picks[g,1]=1
	}
	return(picks)
}

end