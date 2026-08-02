/**
 * Discrete Event Simulation Engine for High Frequency Comparison Engine
 * Supports dual ASGs (Tornado Web ASG 1 & Worker Engine ASG 2)
 */
class DataFlowSimulator {
  constructor(app) {
    this.app = app;
    this.state = 'IDLE';
    this.speed = 1;
    this.timer = null;
    this.stepIndex = 0;
    this.sqsQueue = [];
    this.dlqQueue = [];
    this.efsPickles = [];
    this.activeWorkers = 2;
    this.activeWebInstances = 2;
    this.asgStatus = 'ASG 1 & 2 Idle';
    this.excelGenerated = false;

    this.currentJob = this.createDefaultJob();

    this.steps = [
      {
        id: 'INGESTING',
        name: 'ALB & Nginx Ingestion (ASG 1)',
        activeNodes: ['dCYgY1Jlu9s_', '_JYgZqpwLfiw'],
        activePath: ['dCYgY1Jlu9s_', '_JYgZqpwLfiw'],
        description: 'Client issues HTTP WebHook request. ALB routes traffic to Nginx reverse proxy inside Tornado Web ASG 1 (IAM SG 1).'
      },
      {
        id: 'TORNADO_PROCESS',
        name: 'Tornado Service & RDS PGBouncer (ASG 1)',
        activeNodes: ['vNYgl-vkmlfm', 'MXYgicqMQDyA', '7~Yg.JpiXOLA'],
        activePath: ['_JYgZqpwLfiw', 'vNYgl-vkmlfm', 'MXYgicqMQDyA'],
        description: 'Tornado service accepts request, connects to RDS via PGBouncer DB pool, updates job status, and returns HTTP ACK.'
      },
      {
        id: 'ENQUEUE_SQS',
        name: 'Enqueue Job to AWS SQS',
        activeNodes: ['vNYgl-vkmlfm', 'JT3gnzKKpIAB'],
        activePath: ['vNYgl-vkmlfm', 'JT3gnzKKpIAB'],
        description: 'Tornado service enqueues comparison task into AWS SQS Queue. RDS job status updated to QUEUED.'
      },
      {
        id: 'WORKER_POLL',
        name: 'Worker ASG 2 Pickup from SQS',
        activeNodes: ['JT3gnzKKpIAB', 'HR3gnXg~xIfd', 'nd4g9.oheKrb'],
        activePath: ['JT3gnzKKpIAB', 'HR3gnXg~xIfd'],
        description: 'Worker EC2 Auto-Scaling Group 2 (IAM SG 3) polls SQS. Worker node picks up comparison job.'
      },
      {
        id: 'GATED_PROCESS_POOL',
        name: 'Gated Process-Pool Execution (ASG 2)',
        activeNodes: ['nd4g9.oheKrb', 'qU3gaW2ReJw6'],
        activePath: ['HR3gnXg~xIfd', 'nd4g9.oheKrb'],
        description: 'Comparison Service creates a process-pool. Memory and CPU overhead are bounded using a gated submit() executor.'
      },
      {
        id: 'EFS_PICKLE_WRITE',
        name: 'POSIX EFS Temp Pickle Storage',
        activeNodes: ['nd4g9.oheKrb', '4e4g8QS1AtSn'],
        activePath: ['nd4g9.oheKrb', '4e4g8QS1AtSn'],
        description: 'Multi-process comparison algorithm executes per file. Intermediate pickle files are cached in POSIX-compliant EFS.'
      },
      {
        id: 'RDS_PROGRESS_UPDATE',
        name: 'RDS DB Progress Tracking',
        activeNodes: ['nd4g9.oheKrb', 'MXYgicqMQDyA'],
        activePath: ['nd4g9.oheKrb', 'MXYgicqMQDyA'],
        description: 'On each file comparison completion chunk, worker streams status updates to RDS Instance 1.'
      },
      {
        id: 'EXCEL_COMPILATION',
        name: 'Excel Report 2-Phase Commit',
        activeNodes: ['nd4g9.oheKrb', '4e4g8QS1AtSn', 'MXYgicqMQDyA'],
        activePath: ['nd4g9.oheKrb', '4e4g8QS1AtSn'],
        description: 'Sequential compiler aggregates pickle files into final Excel report in EFS. Finalizes RDS status (2-phase commit).'
      },
      {
        id: 'CLOUDWATCH_METRICS',
        name: 'CloudWatch Telemetry & Dual ASG Scaling',
        activeNodes: ['nd4gBvce91j8', 'CKYgtUlsljJn', 'AFeh-0vD4pMh', 'fIehjI4.2k_w'],
        activePath: ['nd4gBvce91j8', 'AFeh-0vD4pMh', 'fIehjI4.2k_w'],
        description: 'CloudWatch Clients in ASG 1 and ASG 2 push telemetry. CloudAlarm monitors queue depth & CPU, scaling ASG 1 and ASG 2 up/down.'
      }
    ];
  }

  createDefaultJob() {
    return {
      request_id: 'job-' + Math.random().toString(36).substring(2, 9),
      time_stamp: new Date().toISOString().substring(11, 19),
      input_folders: ['folder_1', 'folder_2', 'folder_3'],
      target_folder: ['folder_1_1', 'folder_2_2', 'folder_3_3'],
      show_changed_only: true,
      processed_files: 0,
      total_files: 6,
      retries: 0
    };
  }

  play() {
    if (this.state === 'RUNNING') return;
    this.state = 'RUNNING';
    this.app.log('Starting data flow simulation...', 'info');
    this.runLoop();
  }

  pause() {
    this.state = 'PAUSED';
    if (this.timer) clearTimeout(this.timer);
    this.app.log('Simulation paused.', 'warning');
    this.app.updateStatusUI('Paused at step: ' + this.steps[this.stepIndex].name, 'idle');
  }

  reset() {
    this.pause();
    this.state = 'IDLE';
    this.stepIndex = 0;
    this.sqsQueue = [];
    this.dlqQueue = [];
    this.efsPickles = [];
    this.activeWorkers = 2;
    this.activeWebInstances = 2;
    this.excelGenerated = false;
    this.asgStatus = 'ASG 1 & 2 Idle';
    this.currentJob = this.createDefaultJob();

    this.app.clearActiveHighlights();
    this.app.updateTelemetryUI();
    this.app.updateStatusUI('State: Ready (Click Run Flow)', 'idle');
    this.app.log('Simulation state reset.', 'info');
  }

  stepNext() {
    if (this.stepIndex >= this.steps.length) {
      this.stepIndex = 0;
    }
    this.executeStep(this.stepIndex);
    this.stepIndex++;
    if (this.stepIndex >= this.steps.length) {
      this.state = 'COMPLETED';
      this.app.updateStatusUI('Flow Completed Successfully!', 'active');
      this.app.log('All pipeline stages executed successfully.', 'success');
    }
  }

  runLoop() {
    if (this.state !== 'RUNNING') return;

    if (this.stepIndex < this.steps.length) {
      this.executeStep(this.stepIndex);
      this.stepIndex++;

      const delay = 1800 / this.speed;
      this.timer = setTimeout(() => this.runLoop(), delay);
    } else {
      this.state = 'COMPLETED';
      this.app.updateStatusUI('Flow Completed! Excel report compiled in EFS.', 'active');
      this.app.log('Data flow execution finished. 2-phase commit finalized.', 'success');
    }
  }

  executeStep(idx) {
    const step = this.steps[idx];
    this.app.log(`Step ${idx + 1}/${this.steps.length}: ${step.name} - ${step.description}`, 'info');
    this.app.updateStatusUI(`[${idx + 1}/${this.steps.length}] ${step.name}`, 'active');
    
    this.app.highlightStepNodes(step.activeNodes, step.activePath);

    if (step.id === 'ENQUEUE_SQS') {
      this.sqsQueue.push(this.currentJob);
    } else if (step.id === 'WORKER_POLL') {
      if (this.sqsQueue.length > 0) {
        this.sqsQueue.shift();
      }
    } else if (step.id === 'EFS_PICKLE_WRITE') {
      this.currentJob.processed_files += 2;
      this.efsPickles.push(`pickle_${this.currentJob.processed_files}.pkl`);
    } else if (step.id === 'EXCEL_COMPILATION') {
      this.excelGenerated = true;
      this.currentJob.processed_files = this.currentJob.total_files;
    } else if (step.id === 'CLOUDWATCH_METRICS') {
      if (this.sqsQueue.length > 3) {
        this.activeWorkers = 6;
        this.asgStatus = 'Scaling UP (+4 Workers)';
        this.app.log('CloudAlarm triggered: SQS Queue Depth high -> Scaling ASG 2 up to 6 EC2 instances.', 'warning');
      }
    }

    this.app.updateTelemetryUI();
  }

  setSpeed(val) {
    this.speed = parseFloat(val);
    this.app.log(`Simulation speed set to ${this.speed}x`, 'info');
  }

  submitCustomPayload(inputFolders, targetFolders, showChangedOnly) {
    this.reset();
    this.currentJob = {
      request_id: 'job-custom-' + Math.random().toString(36).substring(2, 7),
      time_stamp: new Date().toISOString().substring(11, 19),
      input_folders: inputFolders.split(',').map(s => s.trim()),
      target_folder: targetFolders.split(',').map(s => s.trim()),
      show_changed_only: showChangedOnly,
      processed_files: 0,
      total_files: inputFolders.split(',').length * 2,
      retries: 0
    };
    this.app.log(`Custom payload submitted: ${this.currentJob.request_id}`, 'success');
    this.play();
  }
}

window.DataFlowSimulator = DataFlowSimulator;
