#' Class for basic queuing system functions
#'
#' Provides the basic functions needed to communicate between machines
#' This should abstract most functions of rZMQ so the scheduler
#' implementations can rely on the higher level functionality
QSys = R6::R6Class("QSys",
    public = list(
        # Create a class instance
        #
        # Initializes ZeroMQ and sets and sets up our primary communication socket
        #
        # @param data    List with elements: fun, const, export, seed
        # @param ports   Range of ports to choose from
        # @param master  rZMQ address of the master (if NULL we create it here)
        initialize = function(data=NULL, ports=6000:8000, master=NULL) {
            private$zmq_context = mget("zmq_context", envir=.GlobalEnv,
                                       ifnotfound = NA)[[1]]
            if (is.na(private$zmq_context)) {
                message("creating new context")
                private$zmq_context = rzmq::init.context()
            } else
                message("reusing context")

            private$socket = rzmq::init.socket(private$zmq_context, "ZMQ_REP")
            private$port = bind_avail(private$socket, ports)
            private$listen = sprintf("tcp://%s:%i",
                                     Sys.info()[['nodename']], private$port)

            if (is.null(master))
                private$master = private$listen
            else
                private$master = master

            if (!is.null(data))
                do.call(self$set_common_data, data)
        },

        # Provides values for job submission template
        #
        # Overwrite this in each derived class
        #
        # @param memory      The amount of memory (megabytes) to request
        # @param log_worker  Create a log file for each worker
        # @return  A list with values:
        #   job_name  : An identifier for the current job
        #   job_group : An common identifier for all jobs handled by this qsys
        #   master    : The rzmq address of the qsys instance we listen on
        #   template  : Named list of template values
        #   log_file  : File name to log workers to
        submit_job = function(template=list(), log_worker=FALSE) {
            # if not called from derived
            # stop("Derived class needs to overwrite submit_job()")

            if (!identical(grepl("://[^:]+:[0-9]+", private$master), TRUE))
                stop("Need to initialize QSys first")

            private$job_num = private$job_num + 1
            values = list(
                job_name = paste0("cmq", private$port, "-", private$job_num),
                job_group = paste("/cmq", Sys.info()[['nodename']], private$port, sep="/"),
                master = private$master
            )
            if (log_worker)
                values$log_file = paste0(values$job_name, ".log")

            private$job_group = values$job_group
            utils::modifyList(template, values)
        },

        set_common_data = function(...) {
            l. = pryr::named_dots(...)
#browser()
            if ("fun" %in% names(l.)) {
                message("\nFUNCTION")
                for (n in ls(environment(l.$fun)))
                    message(n, ": ", pryr::object_size(serialize(get(n, envir=environment(l.$fun)), NULL)))
            }
            if ("const" %in% names(l.)) {
                message("\nCONST")
                for (n in names(l.$const))
                    message(n, ": ", pryr::object_size(serialize(l.$const[[n]], NULL)))
            }

            private$token = paste(sample(letters, 5, TRUE), collapse="")
            private$common_data = serialize(list(id="DO_SETUP",
                        token=private$token, ...), NULL)

#            message("\nargs: ", paste(names(pryr::named_dots(...)), collapse=","))
            message("\nnew common data, size: ", pryr::object_size(private$common_data))
        },

        # Send the data common to all workers, only serialize once
        send_common_data = function(worker_id) {
            if (is.null(private$common_data))
                stop("Need to set_common_data() first")

            #TODO: remove this and fix actual memory leak
            private$common_data_tracker = private$common_data_tracker + 1
            if (private$common_data_tracker %% 10 == 0)
                gc()

            rzmq::send.socket(socket = private$socket,
                              data = private$common_data,
                              serialize = FALSE)
            private$worker_pool[[worker_id]] = TRUE
        },

        # Send iterated data to one worker
        send_job_data = function(...) {
            rzmq::send.socket(socket = private$socket,
                    data = list(id="DO_CHUNK", token=private$token, ...))
        },

        send_wait = function() {
            rzmq::send.socket(socket = private$socket,
                    data=list(id="WORKER_WAIT", wait=0.2*self$workers))
        },

        # Read data from the socket
        receive_data = function(timeout=-1L) {
            rcv = rzmq::poll.socket(list(private$socket),
                                    list("read"), timeout=timeout)

            if (rcv[[1]]$read)
                rzmq::receive.socket(private$socket)
            else # timeout reached
                NULL
        },

        # Send shutdown signal to worker
        send_shutdown_worker = function() {
            rzmq::send.socket(socket = private$socket, data = list(id="WORKER_STOP"))
        },

        disconnect_worker = function(msg) {
            rzmq::send.null.msg(socket = private$socket)
            private$worker_pool[[msg$worker_id]] = NULL
            private$worker_stats[[msg$worker_id]] = msg
        },

        # Make sure all resources are closed properly
        cleanup = function(rt=as.list(1:3)) {
            while(self$workers_running > 0) {
				msg = self$receive_data(timeout=5)
				if (is.null(msg)) {
					warning(sprintf("%i/%i workers did not shut down properly",
							self$workers_running, self$workers), immediate.=TRUE)
					break
				} else if (msg$id == "WORKER_READY")
                    self$send_shutdown_worker()
				else if (msg$id == "WORKER_DONE")
                    self$disconnect_worker(msg)
                else
                    warning("something went wrong during cleanup")
            }

            # compute summary statistics for workers
            times = lapply(private$worker_stats, function(w) w$time)
            wt = Reduce(`+`, times) / length(times)
            message(sprintf("Master: [%.1fs %.1f%% CPU]; Worker average: [%.1f%% CPU]",
                            rt[[3]], 100*(rt[[1]]+rt[[2]])/rt[[3]],
                            100*(wt[[1]]+wt[[2]])/wt[[3]]))
        }
    ),

    active = list(
        # We use the listening port as scheduler ID
        id = function() private$port,
        url = function() private$listen,
        sock = function() private$socket,
        workers = function() private$job_num,
        workers_running = function() length(private$worker_pool),
        data_token = function() private$token
    ),

    private = list(
        zmq_context = NULL,
        socket = NULL,
        port = NA,
        master = NULL,
        listen = NULL,
        job_group = NULL,
        job_num = 0,
        common_data = NULL,
        token = "not set",
        worker_pool = list(),
        worker_stats = list(),
        common_data_tracker = 0 # see if we can limit memory by manual gc()
    ),

    cloneable = FALSE
)
