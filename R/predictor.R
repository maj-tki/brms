# compute predictor terms
predictor <- function(draws, ...) {
  UseMethod("predictor")
}

# compute linear/additive predictor terms
# @param draws a list generated by extract_draws containing
#   all required data and posterior samples
# @param i An optional vector indicating the observation(s) 
#   for which to compute eta. If NULL, eta is computed 
#   for all all observations at once.
# @param fdraws Optional full brmsdraws object of the model. 
#   Currently only needed in non-linear models or for 
#   predicting new data in models with autocorrelation.
# @return Usually an S x N matrix where S is the number of samples
#   and N is the number of observations or length of i if specified. 
#' @export
predictor.bdrawsl <- function(draws, i = NULL, fdraws = NULL, ...) {
  nobs <- ifelse(!is.null(i), length(i), draws$nobs) 
  eta <- matrix(0, nrow = draws$nsamples, ncol = nobs) +
    predictor_fe(draws, i) +
    predictor_re(draws, i) +
    predictor_sp(draws, i) +
    predictor_sm(draws, i) +
    predictor_gp(draws, i) +
    predictor_offset(draws, i, nobs)
  # some autocorrelation structures depend on eta
  eta <- predictor_ac(eta, draws, i, fdraws = fdraws)
  # intentionally last as it may return 3D arrays
  eta <- predictor_cs(eta, draws, i)
  unname(eta)
}

# compute non-linear predictor terms
# @param draws a list generated by extract_draws containing
#   all required data and posterior samples
# @param i An optional vector indicating the observation(s) 
#   for which to compute eta. If NULL, eta is computed 
#   for all all observations at once.
# @param ... further arguments passed to predictor.bdrawsl
# @return Usually an S x N matrix where S is the number of samples
#   and N is the number of observations or length of i if specified.
#' @export
predictor.bdrawsnl <- function(draws, i = NULL, fdraws = NULL, ...) {
  stopifnot(!is.null(fdraws))
  nlpars <- draws$used_nlpars
  covars <- names(draws$C)
  args <- named_list(c(nlpars, covars))
  for (nlp in nlpars) {
    args[[nlp]] <- get_nlpar(fdraws, nlpar = nlp, i = i, ...)
  }
  for (cov in covars) {
    args[[cov]] <- p(draws$C[[cov]], i, row = FALSE)  
  }
  # evaluate non-linear predictor
  eta <- try(eval(draws$nlform, args), silent = TRUE)
  if (is(eta, "try-error")) {
    if (grepl("could not find function", eta)) {
      eta <- rename(eta, "Error in eval(expr, envir, enclos) : ", "")
      message(
        eta, " Most likely this is because you used a Stan ",
        "function in the non-linear model formula that ",
        "is not defined in R. If this is a user-defined function, ",
        "please run 'expose_functions(., vectorize = TRUE)' on ",
        "your fitted model and try again."
      )
    } else {
      eta <- rename(eta, "^Error :", "", fixed = FALSE)
      stop2(eta)
    }
  }
  dim(eta) <- dim(rmNULL(args)[[1]])
  unname(eta)
}

# compute eta for overall effects
predictor_fe <- function(draws, i) {
  fe <- draws[["fe"]]
  if (!isTRUE(ncol(fe[["X"]]) > 0)) {
    return(0) 
  }
  eta <- try(.predictor_fe(X = p(fe[["X"]], i), b = fe[["b"]]))
  if (is(eta, "try-error")) {
    stop2(
      "Something went wrong (see the error message above). ", 
      "Perhaps you transformed numeric variables ", 
      "to factors or vice versa within the model formula? ",
      "If yes, please convert your variables beforehand. ",
      "Or did you set a predictor variable to NA?"
    )
  }
  eta
}

# workhorse function of predictor_fe
# @param X fixed effects design matrix
# @param b samples of fixed effects coeffients
.predictor_fe <- function(X, b) {
  stopifnot(is.matrix(X))
  stopifnot(is.matrix(b))
  tcrossprod(b, X)
}

# compute eta for varying effects
predictor_re <- function(draws, i) {
  eta <- 0
  re <- draws[["re"]]
  group <- names(re[["r"]])
  for (g in group) {
    eta_g <- try(.predictor_re(Z = p(re[["Z"]][[g]], i), r = re[["r"]][[g]]))
    if (is(eta_g, "try-error")) {
      stop2(
        "Something went wrong (see the error message above). ", 
        "Perhaps you transformed numeric variables ", 
        "to factors or vice versa within the model formula? ",
        "If yes, please convert your variables beforehand. ",
        "Or did you use a grouping factor also for a different purpose? ",
        "If yes, please make sure that its factor levels are correct ",
        "also in the new data you may have provided."
      )
    }  
    eta <- eta + eta_g
  }
  eta
}

# workhorse function of predictor_re
# @param Z sparse random effects design matrix
# @param r random effects samples
# @return linear predictor for random effects
.predictor_re <- function(Z, r) {
  Matrix::as.matrix(Matrix::tcrossprod(r, Z))
}

# compute eta for special effects terms
predictor_sp <- function(draws, i) {
  eta <- 0
  sp <- draws[["sp"]]
  if (!length(sp)) {
    return(eta) 
  }
  eval_list <- list()
  for (j in seq_along(sp[["simo"]])) {
    eval_list[[paste0("Xmo_", j)]] <- p(sp[["Xmo"]][[j]], i)
    eval_list[[paste0("simo_", j)]] <- sp[["simo"]][[j]]
  }
  for (j in seq_along(sp[["Xme"]])) {
    eval_list[[paste0("Xme_", j)]] <- p(sp[["Xme"]][[j]], i, row = FALSE)
  }
  for (j in seq_along(sp[["Yl"]])) {
    eval_list[[names(sp[["Yl"]])[j]]] <- p(sp[["Yl"]][[j]], i, row = FALSE)
  }
  for (j in seq_along(sp[["Csp"]])) {
    eval_list[[paste0("Csp_", j)]] <- p(sp[["Csp"]][[j]], i, row = FALSE)
  }
  re <- draws[["re"]]
  spef <- colnames(sp[["bsp"]])
  for (j in seq_along(spef)) {
    # prepare special group-level effects
    rsp <- named_list(names(re[["rsp"]][[spef[j]]]))
    for (g in names(rsp)) {
      rsp[[g]] <- .predictor_re(
        Z = p(re[["Zsp"]][[g]], i), 
        r = re[["rsp"]][[spef[j]]][[g]]
      )
    }
    eta <- eta + .predictor_sp(
      eval_list, call = sp[["calls"]][[j]],
      b = sp[["bsp"]][, j], 
      r = Reduce("+", rsp)
    )
  }
  eta
}

# workhorse function of predictor_sp
# @param call expression for evaluation of special effects
# @param eval_list list containing variables for 'call'
# @param b special effects coefficients samples
# @param r matrix with special effects group-level samples
.predictor_sp <- function(eval_list, call, b, r = NULL) {
  b <- as.vector(b)
  if (is.null(r)) r <- 0 
  (b + r) * eval(call, eval_list)
}

# R implementation of the user defined Stan function 'mo'
# @param simplex posterior samples of a simplex parameter vector
# @param X variable modeled as monotonic
.mo <- function(simplex, X) {
  stopifnot(is.matrix(simplex), is.atomic(X))
  D <- NCOL(simplex)
  simplex <- cbind(0, simplex)
  for (i in seq_cols(simplex)[-1]) {
    # compute the cumulative representation of the simplex 
    simplex[, i] <- simplex[, i] + simplex[, i - 1]
  }
  D * simplex[, X + 1]
}

# compute eta for smooth terms
predictor_sm <- function(draws, i) {
  eta <- 0
  if (!length(draws[["sm"]])) {
    return(eta) 
  }
  fe <- draws[["sm"]]$fe
  if (length(fe)) {
    eta <- eta + .predictor_fe(X = p(fe$Xs, i), b = fe$bs)
  }
  re <- draws[["sm"]]$re
  for (k in seq_along(re)) {
    for (j in seq_along(re[[k]]$s)) {
      Zs <- p(re[[k]]$Zs[[j]], i)
      s <- re[[k]]$s[[j]]
      eta <- eta + .predictor_fe(X = Zs, b = s)
    }
  }
  eta
}

# compute eta for gaussian processes
predictor_gp <- function(draws, i) {
  if (!length(draws[["gp"]])) {
    return(0)
  }
  if (!is.null(i)) {
    stop2("Pointwise evaluation is not supported for Gaussian processes.")
  }
  eta <- matrix(0, nrow = draws$nsamples, ncol = draws$nobs)
  for (k in seq_along(draws[["gp"]])) {
    gp <- draws[["gp"]][[k]]
    if (isTRUE(attr(gp, "byfac"))) {
      # categorical 'by' variable
      for (j in seq_along(gp)) {
        if (length(gp[[j]][["Igp"]])) {
          eta[, gp[[j]][["Igp"]]] <- .predictor_gp(gp[[j]])
        }
      }
    } else {
      eta <- eta + .predictor_gp(gp)
    }
  }
  eta
}

# workhorse function of predictor_gp
# @param gp an list returned by '.extract_draws_gp'
# @return A S x N matrix to be added to the linear predictor
# @note does not work with pointwise evaluation
.predictor_gp <- function(gp) {
  if (is.null(gp[["slambda"]])) {
    # predictions for exact GPs
    nsamples <- length(gp[["sdgp"]])
    eta <- as.list(rep(NA, nsamples))
    if (!is.null(gp[["x_new"]])) {
      for (i in seq_along(eta)) {
        eta[[i]] <- with(gp, .predictor_gp_new(
          x_new = x_new, yL = yL[i, ], x = x, 
          sdgp = sdgp[i], lscale = lscale[i, ], nug = nug
        ))
      }
    } else {
      for (i in seq_along(eta)) {
        eta[[i]] <- with(gp, .predictor_gp_old(
          x = x, sdgp = sdgp[i], lscale = lscale[i, ], 
          zgp = zgp[i, ], nug = nug
        ))
      }
    }
    eta <- do_call(rbind, eta) 
  } else {
    # predictions for approximate GPs
    eta <- with(gp, .predictor_gpa(
      x = x, sdgp = sdgp, lscale = lscale, 
      zgp = zgp, slambda = slambda
    ))
  }
  if (!is.null(gp[["Cgp"]])) {
    eta <- eta * as_draws_matrix(gp[["Cgp"]], dim = dim(eta))
  }
  if (!is.null(gp[["Jgp"]])) {
    eta <- eta[, gp[["Jgp"]], drop = FALSE]
  }
  eta
}

# make exact GP predictions for old data points
# vectorized over posterior samples
# @param x old predictor values
# @param sdgp sample of parameter sdgp
# @param lscale sample of parameter lscale
# @param zgp samples of parameter vector zgp
# @param nug very small positive value to ensure numerical stability
.predictor_gp_old <- function(x, sdgp, lscale, zgp, nug) {
  Sigma <- cov_exp_quad(x, sdgp = sdgp, lscale = lscale)
  lx <- nrow(x)
  Sigma <- Sigma + diag(rep(nug, lx), lx, lx)
  L_Sigma <- try_nug(t(chol(Sigma)), nug = nug)
  as.numeric(L_Sigma %*% zgp)
}

# make exact GP predictions for new data points
# vectorized over posterior samples
# @param x_new new predictor values
# @param yL linear predictor of the old data
# @param x old predictor values
# @param sdgp sample of parameter sdgp
# @param lscale sample of parameter lscale
# @param nug very small positive value to ensure numerical stability
.predictor_gp_new <- function(x_new, yL, x, sdgp, lscale, nug) {
  Sigma <- cov_exp_quad(x, sdgp = sdgp, lscale = lscale)
  lx <- nrow(x)
  lx_new <- nrow(x_new)
  Sigma <- Sigma + diag(rep(nug, lx), lx, lx)
  L_Sigma <- try_nug(t(chol(Sigma)), nug = nug)
  L_Sigma_inverse <- solve(L_Sigma)
  K_div_yL <- L_Sigma_inverse %*% yL
  K_div_yL <- t(t(K_div_yL) %*% L_Sigma_inverse)
  k_x_x_new <- cov_exp_quad(x, x_new, sdgp = sdgp, lscale = lscale)
  mu_yL_new <- as.numeric(t(k_x_x_new) %*% K_div_yL)
  v_new <- L_Sigma_inverse %*% k_x_x_new
  cov_yL_new <- cov_exp_quad(x_new, sdgp = sdgp, lscale = lscale) -
    t(v_new) %*% v_new + diag(rep(nug, lx_new), lx_new, lx_new)
  yL_new <- try_nug(
    rmulti_normal(1, mu = mu_yL_new, Sigma = cov_yL_new),
    nug = nug
  )
  return(yL_new)
}

# make predictions for approximate GPs
# vectorized over posterior samples
# @param x matrix of evaluated eigenfunctions of the cov matrix
# @param sdgp sample of parameter sdgp
# @param lscale sample of parameter lscale
# @param zgp samples of parameter vector zgp
# @param slambda vector of eigenvalues of the cov matrix
# @note no need to differentiate between old and new data points
.predictor_gpa <- function(x, sdgp, lscale, zgp, slambda) {
  spd <- sqrt(spd_cov_exp_quad(slambda, sdgp, lscale))
  (spd * zgp) %*% t(x)
}

# compute eta for category specific effects
# @param predictor matrix of other additive terms
# @return 3D predictor array in the presence of 'cs' effects
#   otherwise return 'eta' unchanged
predictor_cs <- function(eta, draws, i) {
  cs <- draws[["cs"]]
  re <- draws[["re"]]
  if (!length(cs[["bcs"]]) && !length(re[["rcs"]])) {
    return(eta)
  }
  nthres <- cs[["nthres"]]
  rcs <- NULL
  if (!is.null(re[["rcs"]])) {
    groups <- names(re[["rcs"]])
    rcs <- vector("list", nthres)
    for (k in seq_along(rcs)) {
      rcs[[k]] <- named_list(groups)
      for (g in groups) {
        rcs[[k]][[g]] <- .predictor_re(
          Z = p(re[["Zcs"]][[g]], i),
          r = re[["rcs"]][[g]][[k]]
        )
      }
      rcs[[k]] <- Reduce("+", rcs[[k]])
    }
  }
  .predictor_cs(
    eta, X = p(cs[["Xcs"]], i), 
    b = cs[["bcs"]], nthres = nthres, r = rcs
  )
}

# workhorse function of predictor_cs
# @param X category specific design matrix 
# @param b category specific effects samples
# @param nthres number of thresholds
# @param eta linear predictor matrix
# @param r list of samples of cs group-level effects
# @return 3D predictor array including category specific effects
.predictor_cs <- function(eta, X, b, nthres, r = NULL) {
  stopifnot(is.null(X) && is.null(b) || is.matrix(X) && is.matrix(b))
  nthres <- max(nthres)
  eta <- predictor_expand(eta, nthres)
  if (!is.null(X)) {
    I <- seq(1, (nthres) * ncol(X), nthres) - 1
    X <- t(X)
  }
  for (k in seq_len(nthres)) {
    if (!is.null(X)) {
      eta[, , k] <- eta[, , k] + b[, I + k, drop = FALSE] %*% X 
    }
    if (!is.null(r[[k]])) {
      eta[, , k] <- eta[, , k] + r[[k]]
    }
  }
  eta
}

# expand dimension of the predictor matrix to a 3D array
predictor_expand <- function(eta, nthres) {
  if (length(dim(eta)) == 2L) {
    eta <- array(eta, dim = c(dim(eta), nthres))    
  }
  eta
}

predictor_offset <- function(draws, i, nobs) {
  if (is.null(draws$offset)) {
    return(0) 
  }
  eta <- rep(p(draws$offset, i), draws$nsamples)
  matrix(eta, ncol = nobs, byrow = TRUE)
}

# compute eta for autocorrelation structures
# @note eta has to be passed to this function in 
#   order for ARMA structures to work correctly
predictor_ac <- function(eta, draws, i, fdraws = NULL) {
  if (has_ac_class(draws$ac$acef, "arma")) {
    if (!is.null(draws$ac$err)) {
      # ARMA correlations via latent residuals
      eta <- eta + p(draws$ac$err, i, row = FALSE)
    } else {
      # ARMA correlations via explicit natural residuals
      if (!is.null(i)) {
        stop2("Pointwise evaluation is not possible for ARMA models.")
      }
      eta <- .predictor_arma(
        eta, ar = draws$ac$ar, ma = draws$ac$ma, 
        Y = draws$ac$Y, J_lag = draws$ac$J_lag, 
        fdraws = fdraws
      ) 
    }
  }
  if (has_ac_class(draws$ac$acef, "car")) {
    eta <- eta + .predictor_re(Z = p(draws$ac$Zcar, i), r = draws$ac$rcar)
  }
  eta
}

# add ARMA effects to a predictor matrix
# @param eta linear predictor matrix
# @param ar optional autoregressive samples
# @param ma optional moving average samples
# @param Y vector of response values
# @param J_lag autocorrelation lag for each observation
# @return linear predictor matrix updated by ARMA effects
.predictor_arma <- function(eta, ar = NULL, ma = NULL, Y = NULL, J_lag = NULL,
                            fdraws = NULL) {
  if (is.null(ar) && is.null(ma)) {
    return(eta)
  }
  if (anyNA(Y)) {
    # predicting Y will be necessary at some point
    stopifnot(is.brmsdraws(fdraws) || is.mvbrmsdraws(fdraws))
    pp_fun <- paste0("posterior_predict_", fdraws$family$fun)
    pp_fun <- get(pp_fun, asNamespace("brms"))
  }
  S <- nrow(eta)
  N <- length(Y)
  max_lag <- max(J_lag, 1)
  Kar <- ifelse(is.null(ar), 0, ncol(ar))
  Kma <- ifelse(is.null(ma), 0, ncol(ma))
  # relevant if time-series are shorter than the ARMA orders
  take_ar <- seq_len(min(Kar, max_lag))
  take_ma <- seq_len(min(Kma, max_lag))
  ar <- ar[, take_ar, drop = FALSE]
  ma <- ma[, take_ma, drop = FALSE]
  Err <- array(0, dim = c(S, max_lag, max_lag + 1))
  err <- zero_mat <- matrix(0, nrow = S, ncol = max_lag)
  zero_vec <- rep(0, S)
  for (n in seq_len(N)) {
    if (Kma) {
      eta[, n] <- eta[, n] + rowSums(ma * Err[, take_ma, max_lag])
    }
    eta_before_ar <- eta[, n]
    if (Kar) {
      eta[, n] <- eta[, n] + rowSums(ar * Err[, take_ar, max_lag])
    }
    # AR terms need to be included in the predictions of y if missing
    # the prediction code thus differs from the structure of the Stan code
    y <- Y[n]
    if (is.na(y)) {
      # y was not observed and has to be predicted
      fdraws$dpars$mu <- eta
      y <- pp_fun(n, fdraws)
    }
    # errors in AR models need to be computed before adding AR terms
    err[, max_lag] <- y - eta_before_ar
    if (J_lag[n] > 0) {
      # store residuals of former observations
      I <- seq_len(J_lag[n])
      Err[, I, max_lag + 1] <- err[, max_lag + 1 - I]
    }
    # keep the size of 'err' and 'Err' as small as possible
    Err <- abind(Err[, , -1, drop = FALSE], zero_mat)
    err <- cbind(err[, -1, drop = FALSE], zero_vec)
  }
  eta
}
