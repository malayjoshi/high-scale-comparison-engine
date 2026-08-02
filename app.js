/**
 * Main Controller & Architecture Visualizer for High Frequency Comparison Engine
 * Features Longest-Segment Anchor Placement & Padded Pill Badges to display connection texts fully.
 */
class ArchitectureApp {
  constructor() {
    this.canvas = document.getElementById('architecture-canvas');
    this.ctx = this.canvas.getContext('2d');
    
    this.diagramData = null;
    this.containers = [];
    this.nodes = [];
    this.connections = [];
    
    // Viewport transform (Pan & Zoom)
    this.zoom = 0.8;
    this.panX = 30;
    this.panY = 20;
    this.isDragging = false;
    this.dragStart = { x: 0, y: 0 };

    // SVG Viewport transform
    this.svgZoom = 0.6;
    this.svgPanX = 0;
    this.svgPanY = 0;
    this.isSvgDragging = false;
    this.svgDragStart = { x: 0, y: 0 };
    
    this.selectedNode = null;
    this.activeNodeIds = new Set();
    this.activePathIds = new Set();
    this.particles = [];

    this.simulator = new DataFlowSimulator(this);

    this.init();
  }

  async init() {
    this.setupCanvasSize();
    window.addEventListener('resize', () => this.setupCanvasSize());

    await this.loadDiagramData();
    this.buildNodeGraph();
    this.setupEventListeners();
    this.setupTabListeners();

    // Start render loop
    requestAnimationFrame((t) => this.renderLoop(t));
    
    this.updateTelemetryUI();
    this.updatePayloadPreview();
    
    // Auto-select Tornado ASG service
    this.selectNode('vNYgl-vkmlfm');
  }

  setupCanvasSize() {
    const rect = this.canvas.parentElement.getBoundingClientRect();
    this.canvas.width = rect.width * window.devicePixelRatio;
    this.canvas.height = rect.height * window.devicePixelRatio;
    this.ctx.scale(window.devicePixelRatio, window.devicePixelRatio);
  }

  async loadDiagramData() {
    try {
      const response = await fetch('diagram.json');
      this.diagramData = await response.json();
      document.getElementById('lucid-json-viewer').textContent = JSON.stringify(this.diagramData, null, 2);
    } catch (e) {
      console.warn('Fallback to embedded JSON:', e);
    }
  }

  buildNodeGraph() {
    // 1. Structural Auto-Scaling Group Containers
    this.containers = [
      {
        id: 'asg_tornado_container',
        label: 'EC2 Auto-Scaling Group (ASG 1) - Tornado Web Tier',
        sg: 'IAM SG 1',
        x: 230, y: 90, w: 460, h: 420,
        color: 'rgba(0, 242, 254, 0.10)',
        borderColor: '#00f2fe'
      },
      {
        id: 'asg_worker_container',
        label: 'EC2 Auto-Scaling Group (ASG 2) - Worker Engine Tier',
        sg: 'IAM SG 3',
        x: 910, y: 90, w: 470, h: 420,
        color: 'rgba(127, 0, 255, 0.10)',
        borderColor: '#7f00ff'
      }
    ];

    // 2. Component Nodes with expanded dimensions
    this.nodes = [
      // Ingestion / LB
      { id: 'dCYgY1Jlu9s_', label: 'ALB\nLoad Balancer', type: 'AWS Application Load Balancer', group: 'Ingestion', x: 30, y: 150, w: 150, h: 70, color: '#e056fd' },
      
      // Inside ASG 1 (Tornado Web Service ASG)
      { id: '_JYgZqpwLfiw', label: 'Nginx', type: 'Reverse Proxy', group: 'ASG 1 / EC2', x: 260, y: 145, w: 120, h: 60, color: '#00f5a0' },
      { id: 'vNYgl-vkmlfm', label: 'Tornado Service\nPrometheus | NodeMonitor', type: 'Tornado Web API Server', group: 'ASG 1 / Docker', x: 410, y: 145, w: 250, h: 75, color: '#00f2fe' },
      { id: 'nd4gBvce91j8', label: 'CloudWatch Client 1', type: 'Metrics Collector', group: 'ASG 1 / Telemetry', x: 260, y: 430, w: 160, h: 60, color: '#ff9f43' },
      { id: '7~Yg.JpiXOLA', label: 'Tornado Responsibilities:\n• Serves request & sends ACK\n• Enqueues request to SQS\n• Updates DB with job status\n• Polls RDS & triggers callback URL', type: 'Execution Spec', group: 'ASG 1 / Logic', x: 410, y: 245, w: 250, h: 245, color: '#00f2fe' },

      // SQS Queue Layer
      { id: 'JT3gnzKKpIAB', label: 'SQS Queue', type: 'AWS SQS Queue', group: 'Messaging', x: 730, y: 150, w: 140, h: 65, color: '#ffb703' },
      { id: '2ZdhqCsXTpb1', label: 'Dead Letter Queue (DLQ)\nMaxRetries = 5 (job_id)', type: 'AWS SQS DLQ', group: 'Messaging', x: 730, y: 270, w: 150, h: 75, color: '#ff0055' },

      // Inside ASG 2 (Worker Comparison Engine ASG)
      { id: 'HR3gnXg~xIfd', label: 'EC2 Worker Nodes', type: 'Worker EC2 Instance Pool', group: 'ASG 2 / EC2', x: 940, y: 145, w: 160, h: 60, color: '#7f00ff' },
      { id: 'nd4g9.oheKrb', label: 'Comparison Service\nPrometheus | NodeMonitor', type: 'Execution Engine', group: 'ASG 2 / Docker', x: 1120, y: 145, w: 230, h: 75, color: '#b56bff' },
      { id: 'CKYgtUlsljJn', label: 'CloudWatch Client 2', type: 'Metrics Collector', group: 'ASG 2 / Telemetry', x: 940, y: 430, w: 160, h: 60, color: '#ff9f43' },
      { id: 'qU3gaW2ReJw6', label: 'Worker Responsibilities:\n• Picks job from SQS & spawns process-pool\n• Runs file comparison & saves EFS pickle\n• Offloads memory & updates RDS per file\n• Gated submit() executor limits CPU/RAM\n• Sequentially compiles Excel report (2PC)', type: 'Execution Spec', group: 'ASG 2 / Logic', x: 1120, y: 240, w: 230, h: 250, color: '#b56bff' },

      // Storage & Databases Tier (Y = 555)
      { id: 'MXYgicqMQDyA', label: 'RDS (Inst-1)\nPGBouncer DB Pool', type: 'PostgreSQL Database', group: 'Database', x: 440, y: 555, w: 240, h: 75, color: '#38ef7d' },
      { id: '4e4g8QS1AtSn', label: 'EFS POSIX Store\nTemp Pickle & Excel', type: 'AWS EFS Storage', group: 'Storage', x: 1020, y: 555, w: 240, h: 75, color: '#4facfe' },

      // Telemetry & Alarm Tier (Y = 680)
      { id: 'AFeh-0vD4pMh', label: 'CloudWatch Hub', type: 'Central Telemetry Hub', group: 'Monitoring', x: 500, y: 680, w: 180, h: 65, color: '#ff9f43' },
      { id: 'fIehjI4.2k_w', label: 'CloudAlarm\n(ASG Trigger Up/Down)', type: 'AWS Alarm Service', group: 'Monitoring', x: 790, y: 680, w: 190, h: 65, color: '#ee5253' }
    ];

    // 3. Connection Channels with Optimized Waypoints
    this.connections = [
      { 
        from: 'dCYgY1Jlu9s_', to: '_JYgZqpwLfiw', label: 'HTTPS Request',
        waypoints: [{ x: 180, y: 175 }, { x: 260, y: 175 }]
      },
      { 
        from: '_JYgZqpwLfiw', to: 'vNYgl-vkmlfm', label: 'WebHook',
        waypoints: [{ x: 380, y: 175 }, { x: 410, y: 175 }]
      },
      { 
        from: 'vNYgl-vkmlfm', to: 'MXYgicqMQDyA', label: 'PGBouncer Conn',
        waypoints: [{ x: 560, y: 220 }, { x: 560, y: 555 }]
      },
      { 
        from: 'vNYgl-vkmlfm', to: 'JT3gnzKKpIAB', label: 'Enqueue Job',
        waypoints: [{ x: 660, y: 180 }, { x: 730, y: 180 }]
      },
      { 
        from: 'JT3gnzKKpIAB', to: '2ZdhqCsXTpb1', label: 'MaxRetries > 5',
        waypoints: [{ x: 800, y: 215 }, { x: 800, y: 270 }]
      },
      { 
        from: 'JT3gnzKKpIAB', to: 'HR3gnXg~xIfd', label: 'Poll SQS Job',
        waypoints: [{ x: 870, y: 175 }, { x: 940, y: 175 }]
      },
      { 
        from: 'HR3gnXg~xIfd', to: 'nd4g9.oheKrb', label: 'Gated Process Pool',
        waypoints: [{ x: 1100, y: 175 }, { x: 1120, y: 175 }]
      },
      { 
        from: 'nd4g9.oheKrb', to: '4e4g8QS1AtSn', label: 'Pickle & Excel IO',
        waypoints: [{ x: 1235, y: 220 }, { x: 1235, y: 555 }]
      },
      { 
        from: 'nd4g9.oheKrb', to: 'MXYgicqMQDyA', label: 'RDS Progress & 2PC',
        waypoints: [{ x: 1350, y: 185 }, { x: 1400, y: 185 }, { x: 1400, y: 640 }, { x: 560, y: 640 }, { x: 560, y: 630 }]
      },
      { 
        from: 'nd4gBvce91j8', to: 'AFeh-0vD4pMh', label: 'ASG 1 Metrics',
        waypoints: [{ x: 340, y: 490 }, { x: 340, y: 712 }, { x: 500, y: 712 }]
      },
      { 
        from: 'CKYgtUlsljJn', to: 'AFeh-0vD4pMh', label: 'ASG 2 Metrics',
        waypoints: [{ x: 1020, y: 490 }, { x: 1020, y: 650 }, { x: 740, y: 650 }, { x: 740, y: 712 }, { x: 680, y: 712 }]
      },
      { 
        from: 'AFeh-0vD4pMh', to: 'fIehjI4.2k_w', label: 'Trigger Metric',
        waypoints: [{ x: 680, y: 712 }, { x: 790, y: 712 }]
      },
      { 
        from: 'fIehjI4.2k_w', to: 'asg_tornado_container', label: 'ASG 1 Scaling',
        waypoints: [{ x: 885, y: 745 }, { x: 190, y: 745 }, { x: 190, y: 300 }, { x: 230, y: 300 }]
      },
      { 
        from: 'fIehjI4.2k_w', to: 'asg_worker_container', label: 'ASG 2 Scaling',
        waypoints: [{ x: 885, y: 745 }, { x: 1430, y: 745 }, { x: 1430, y: 300 }, { x: 1380, y: 300 }]
      }
    ];
  }

  setupEventListeners() {
    // Simulator control buttons
    document.getElementById('btn-play').addEventListener('click', () => this.simulator.play());
    document.getElementById('btn-step').addEventListener('click', () => this.simulator.stepNext());
    document.getElementById('btn-reset').addEventListener('click', () => this.simulator.reset());
    document.getElementById('speed-select').addEventListener('change', (e) => this.simulator.setSpeed(e.target.value));

    // Drawer toggles
    document.getElementById('btn-toggle-drawer').addEventListener('click', () => this.toggleDrawer());
    document.getElementById('btn-close-drawer').addEventListener('click', () => this.closeDrawer());

    // Zoom & Pan controls
    document.getElementById('btn-zoom-in').addEventListener('click', () => this.zoomAt(1.2));
    document.getElementById('btn-zoom-out').addEventListener('click', () => this.zoomAt(0.8));
    document.getElementById('btn-zoom-reset').addEventListener('click', () => {
      this.zoom = 0.8;
      this.panX = 30;
      this.panY = 20;
      this.svgZoom = 0.6;
      this.svgPanX = 0;
      this.svgPanY = 0;
      this.updateSvgTransform();
    });

    // Custom payload submit button
    document.getElementById('btn-submit-custom-payload').addEventListener('click', () => {
      const inputs = document.getElementById('payload-input-folders').value;
      const targets = document.getElementById('payload-target-folders').value;
      const showChanged = document.getElementById('payload-show-changed').checked;
      this.simulator.submitCustomPayload(inputs, targets, showChanged);
      this.closeDrawer();
    });

    document.getElementById('clear-logs').addEventListener('click', () => {
      document.getElementById('log-stream').innerHTML = '';
    });

    // Form preview updates
    ['payload-input-folders', 'payload-target-folders', 'payload-show-changed'].forEach(id => {
      const el = document.getElementById(id);
      if (el) el.addEventListener('input', () => this.updatePayloadPreview());
    });

    // View mode toggle listeners
    const btnCanvas = document.getElementById('btn-view-canvas');
    const btnSvg = document.getElementById('btn-view-svg');
    const canvasEl = document.getElementById('architecture-canvas');
    const svgWrapper = document.getElementById('svg-viewer-wrapper');

    if (btnCanvas && btnSvg) {
      btnCanvas.addEventListener('click', () => {
        btnCanvas.classList.add('active');
        btnSvg.classList.remove('active');
        canvasEl.style.display = 'block';
        svgWrapper.style.display = 'none';
        this.log('Switched view to Interactive Flow Canvas.', 'info');
      });

      btnSvg.addEventListener('click', () => {
        btnSvg.classList.add('active');
        btnCanvas.classList.remove('active');
        canvasEl.style.display = 'none';
        svgWrapper.style.display = 'flex';
        this.updateSvgTransform();
        this.log('Switched view to Original Lucidchart SVG Vector Diagram.', 'info');
      });
    }

    // SVG Dragging & Mouse Wheel Zoom
    if (svgWrapper) {
      svgWrapper.addEventListener('wheel', (e) => {
        e.preventDefault();
        const factor = e.deltaY < 0 ? 1.15 : 0.85;
        this.zoomAt(factor);
      }, { passive: false });

      svgWrapper.addEventListener('mousedown', (e) => {
        this.isSvgDragging = true;
        svgWrapper.style.cursor = 'grabbing';
        this.svgDragStart = { x: e.clientX - this.svgPanX, y: e.clientY - this.svgPanY };
      });

      window.addEventListener('mousemove', (e) => {
        if (this.isSvgDragging) {
          this.svgPanX = e.clientX - this.svgDragStart.x;
          this.svgPanY = e.clientY - this.svgDragStart.y;
          this.updateSvgTransform();
        }
      });

      window.addEventListener('mouseup', () => {
        this.isSvgDragging = false;
        if (svgWrapper) svgWrapper.style.cursor = 'grab';
      });
    }

    // Canvas Pointer events for dragging & clicking
    this.canvas.addEventListener('mousedown', (e) => {
      this.isDragging = true;
      this.dragStart = { x: e.clientX - this.panX, y: e.clientY - this.panY };
    });

    this.canvas.addEventListener('wheel', (e) => {
      e.preventDefault();
      const factor = e.deltaY < 0 ? 1.15 : 0.85;
      this.zoomAt(factor);
    }, { passive: false });

    window.addEventListener('mousemove', (e) => {
      if (this.isDragging) {
        this.panX = e.clientX - this.dragStart.x;
        this.panY = e.clientY - this.dragStart.y;
      }
    });

    window.addEventListener('mouseup', () => {
      this.isDragging = false;
    });

    this.canvas.addEventListener('click', (e) => {
      const rect = this.canvas.getBoundingClientRect();
      const clickX = (e.clientX - rect.left - this.panX) / this.zoom;
      const clickY = (e.clientY - rect.top - this.panY) / this.zoom;

      const clickedNode = this.nodes.find(n => 
        clickX >= n.x && clickX <= n.x + n.w &&
        clickY >= n.y && clickY <= n.y + n.h
      );

      if (clickedNode) {
        this.selectNode(clickedNode.id);
      }
    });
  }

  setupTabListeners() {
    const tabs = document.querySelectorAll('.tab-btn');
    tabs.forEach(btn => {
      btn.addEventListener('click', () => {
        tabs.forEach(t => t.classList.remove('active'));
        document.querySelectorAll('.tab-content').forEach(c => c.classList.remove('active'));
        
        btn.classList.add('active');
        const target = btn.getAttribute('data-tab');
        document.getElementById(target).classList.add('active');
      });
    });
  }

  zoomAt(factor) {
    const btnSvg = document.getElementById('btn-view-svg');
    const isSvgActive = btnSvg && btnSvg.classList.contains('active');

    if (isSvgActive) {
      this.svgZoom = Math.min(Math.max(this.svgZoom * factor, 0.2), 3.0);
      this.updateSvgTransform();
    } else {
      this.zoom = Math.min(Math.max(this.zoom * factor, 0.35), 2.5);
    }
  }

  updateSvgTransform() {
    const img = document.getElementById('lucidchart-svg-img');
    if (img) {
      img.style.transform = `translate(${this.svgPanX}px, ${this.svgPanY}px) scale(${this.svgZoom})`;
    }
  }

  toggleDrawer() {
    document.getElementById('drawer-panel').classList.toggle('open');
  }

  openDrawer() {
    document.getElementById('drawer-panel').classList.add('open');
  }

  closeDrawer() {
    document.getElementById('drawer-panel').classList.remove('open');
  }

  selectNode(nodeId) {
    const node = this.nodes.find(n => n.id === nodeId);
    if (!node) return;

    this.selectedNode = node;
    this.openDrawer();

    document.getElementById('inspector-node-name').textContent = node.label.split('\n')[0];
    document.getElementById('inspector-node-type').textContent = `Type: ${node.type} | Group: ${node.group}`;

    let desc = '';
    let notes = '';

    if (node.id === 'vNYgl-vkmlfm') {
      desc = 'Tornado Web Service running inside EC2 Auto-Scaling Group 1 (IAM SG 1). Serves incoming HTTP API requests via ALB and Nginx reverse proxy, manages PGBouncer RDS connections, and enqueues jobs to SQS.';
      notes = 'Serves request\nEnqueues request to SQS\nUpdates DB with status\nSends back ACK\nPolls RDS for job update\nCallback URL gets triggered';
    } else if (node.id === 'nd4g9.oheKrb') {
      desc = 'Comparison Service worker engine running inside EC2 Auto-Scaling Group 2 (IAM SG 3). Pulls comparison tasks from SQS Queue, creates multi-process pool, and enforces gated submit() executor.';
      notes = 'Picks up job from SQS\nCreate a process-pool\nRun normal comparison algorithm per process\nCreate a temporary folder in EFS and save pickle file of each comparison and offload memory (No S3 since EFS is low latency service, good for temporary files and POSIX compliant)\nOn each file comparison completion update RDS\nTo curtail memory/cpu usage from going over limit, use gated submit() executor.\nOnce all comparisons are done, run a function which sequentially writes results to excel.\nUpdate RDS status and save excel report to EFS (2 phase commit).';
    } else if (node.id === '4e4g8QS1AtSn') {
      desc = 'AWS Elastic File System (EFS). Low-latency, POSIX-compliant file system used by Worker ASG to cache temporary .pickle files and write final compiled Excel reports.';
      notes = 'No S3 used since EFS is low latency, good for temporary files and POSIX compliant file locking.';
    } else if (node.id === '2ZdhqCsXTpb1') {
      desc = 'AWS SQS Dead Letter Queue (DLQ). Catches failed comparison tasks exceeding MaxRetries = 5 (job_id).';
      notes = 'MaxRetries = 5 (job_id)\nIsolates broken payloads for debugging.';
    } else {
      desc = `${node.label} component of the High Frequency Comparison Engine architecture.`;
      notes = `Component ID: ${node.id}\nGroup: ${node.group}\nStatus: Active`;
    }

    document.getElementById('inspector-node-desc').textContent = desc;
    document.getElementById('inspector-node-notes').textContent = notes;
  }

  highlightStepNodes(nodeIds, pathNodeIds) {
    this.activeNodeIds = new Set(nodeIds);
    this.activePathIds = new Set(pathNodeIds);

    for (let i = 0; i < pathNodeIds.length - 1; i++) {
      const conn = this.connections.find(c => c.from === pathNodeIds[i] && c.to === pathNodeIds[i + 1]);
      if (conn && conn.waypoints && conn.waypoints.length >= 2) {
        const startPoint = conn.waypoints[0];
        this.particles.push({
          waypoints: conn.waypoints,
          waypointIdx: 0,
          x: startPoint.x,
          y: startPoint.y,
          progress: 0,
          speed: 0.04 * this.simulator.speed,
          color: '#00f2fe'
        });
      }
    }
  }

  clearActiveHighlights() {
    this.activeNodeIds.clear();
    this.activePathIds.clear();
    this.particles = [];
  }

  updateStatusUI(text, pulseState) {
    document.getElementById('status-text').textContent = text;
    const pulseEl = document.getElementById('status-pulse');
    pulseEl.className = `pulse-dot ${pulseState}`;
  }

  updateTelemetryUI() {
    document.getElementById('stat-sqs-depth').textContent = this.simulator.sqsQueue.length;
    document.getElementById('stat-workers-active').textContent = this.simulator.activeWorkers;
    document.getElementById('stat-efs-files').textContent = this.simulator.efsPickles.length;
    document.getElementById('stat-rds-conns').textContent = 4 + (this.simulator.activeWorkers * 2);
    
    document.getElementById('asg-status-badge').textContent = this.simulator.asgStatus;

    const pct = Math.round((this.simulator.currentJob.processed_files / this.simulator.currentJob.total_files) * 100);
    document.getElementById('job-progress-pct').textContent = `${pct}%`;
    document.getElementById('job-progress-fill').style.width = `${pct}%`;
  }

  updatePayloadPreview() {
    const inputs = document.getElementById('payload-input-folders').value.split(',').map(s => s.trim());
    const targets = document.getElementById('payload-target-folders').value.split(',').map(s => s.trim());
    const showChanged = document.getElementById('payload-show-changed').checked;

    if (!document.getElementById('payload-uuid').value) {
      document.getElementById('payload-uuid').value = 'job-uuid-' + Math.random().toString(36).substring(2, 9);
    }

    const payloadObj = {
      request_id: document.getElementById('payload-uuid').value,
      time_stamp: new Date().toISOString(),
      input_folders: inputs,
      target_folder: targets,
      show_changed_only: showChanged
    };

    document.getElementById('payload-json-preview').textContent = JSON.stringify(payloadObj, null, 2);
  }

  log(msg, type = 'info') {
    const logContainer = document.getElementById('log-stream');
    const entry = document.createElement('div');
    entry.className = `log-entry ${type}`;
    const time = new Date().toTimeString().substring(0, 8);
    entry.innerHTML = `<span class="log-time">${time}</span> ${msg}`;
    logContainer.appendChild(entry);
    logContainer.scrollTop = logContainer.scrollHeight;
  }

  renderLoop() {
    const width = this.canvas.width / window.devicePixelRatio;
    const height = this.canvas.height / window.devicePixelRatio;

    this.ctx.clearRect(0, 0, width, height);

    this.ctx.save();
    this.ctx.translate(this.panX, this.panY);
    this.ctx.scale(this.zoom, this.zoom);

    // 1. Outer AWS VPC Container
    this.drawVpcBoundaries();

    // 2. Draw Auto-Scaling Group (ASG 1 & ASG 2) Containers
    this.drawAsgContainers();

    // 3. Draw Connection Poly-Lines
    this.drawConnections();

    // 4. Draw Component Nodes with Word Wrapping
    this.drawNodes();

    // 5. Update & Draw Particles along Waypoints
    this.updateAndDrawParticles();

    this.ctx.restore();

    requestAnimationFrame(() => this.renderLoop());
  }

  drawVpcBoundaries() {
    this.ctx.save();
    this.ctx.strokeStyle = 'rgba(0, 242, 254, 0.15)';
    this.ctx.lineWidth = 1.5;
    this.ctx.setLineDash([8, 8]);

    this.ctx.strokeRect(10, 40, 1440, 740);
    this.ctx.fillStyle = 'rgba(0, 242, 254, 0.015)';
    this.ctx.fillRect(10, 40, 1440, 740);

    this.ctx.font = '700 13px "JetBrains Mono", monospace';
    this.ctx.fillStyle = 'rgba(0, 242, 254, 0.6)';
    this.ctx.fillText('AWS VPC (Virtual Private Cloud)', 25, 65);

    this.ctx.restore();
  }

  drawAsgContainers() {
    this.containers.forEach(asg => {
      this.ctx.save();
      this.ctx.strokeStyle = asg.borderColor;
      this.ctx.lineWidth = 2;
      this.ctx.setLineDash([6, 4]);

      this.ctx.fillStyle = asg.color;
      this.roundRect(asg.x, asg.y, asg.w, asg.h, 12, true, true);

      // ASG Header Title
      this.ctx.font = '700 12px "Inter", sans-serif';
      this.ctx.fillStyle = '#ffffff';
      this.ctx.fillText(asg.label, asg.x + 14, asg.y + 24);

      // Security Group Tag Badge
      const badgeW = 75;
      const badgeX = asg.x + asg.w - badgeW - 14;
      this.ctx.fillStyle = 'rgba(0, 0, 0, 0.4)';
      this.roundRect(badgeX, asg.y + 10, badgeW, 20, 10, true, false);
      
      this.ctx.font = '700 10px "JetBrains Mono", monospace';
      this.ctx.fillStyle = asg.borderColor;
      this.ctx.fillText(asg.sg, badgeX + 8, asg.y + 24);

      this.ctx.restore();
    });
  }

  drawConnections() {
    this.connections.forEach(conn => {
      const isPathActive = this.activePathIds.has(conn.from) && this.activePathIds.has(conn.to);

      this.ctx.save();
      this.ctx.beginPath();

      if (conn.waypoints && conn.waypoints.length > 0) {
        this.ctx.moveTo(conn.waypoints[0].x, conn.waypoints[0].y);
        for (let i = 1; i < conn.waypoints.length; i++) {
          this.ctx.lineTo(conn.waypoints[i].x, conn.waypoints[i].y);
        }
      }

      if (isPathActive) {
        this.ctx.strokeStyle = '#00f2fe';
        this.ctx.lineWidth = 3.5;
        this.ctx.shadowColor = '#00f2fe';
        this.ctx.shadowBlur = 12;
      } else {
        this.ctx.strokeStyle = 'rgba(255, 255, 255, 0.18)';
        this.ctx.lineWidth = 1.5;
      }
      this.ctx.stroke();

      // Find the LONGEST polyline segment to anchor the connection label cleanly
      if (conn.label && conn.waypoints && conn.waypoints.length >= 2) {
        let longestSegIndex = 0;
        let maxSegLength = 0;

        for (let i = 0; i < conn.waypoints.length - 1; i++) {
          const dx = conn.waypoints[i + 1].x - conn.waypoints[i].x;
          const dy = conn.waypoints[i + 1].y - conn.waypoints[i].y;
          const len = Math.hypot(dx, dy);
          if (len > maxSegLength) {
            maxSegLength = len;
            longestSegIndex = i;
          }
        }

        const p1 = conn.waypoints[longestSegIndex];
        const p2 = conn.waypoints[longestSegIndex + 1];
        const midX = (p1.x + p2.x) / 2;
        const midY = (p1.y + p2.y) / 2;

        this.ctx.font = '600 11px "Inter", sans-serif';
        this.ctx.textBaseline = 'middle';
        this.ctx.textAlign = 'center';

        const textWidth = this.ctx.measureText(conn.label).width;
        const pillW = textWidth + 24;
        const pillH = 22;
        const pillX = midX - pillW / 2;
        const pillY = midY - pillH / 2;

        // Draw Dark Pill Badge
        this.ctx.fillStyle = 'rgba(5, 8, 16, 0.95)';
        this.ctx.strokeStyle = isPathActive ? '#00f2fe' : 'rgba(255, 255, 255, 0.25)';
        this.ctx.lineWidth = 1.2;
        this.roundRect(pillX, pillY, pillW, pillH, 10, true, true);

        // Draw Centered Text Label
        this.ctx.fillStyle = isPathActive ? '#00f2fe' : '#f0f4f8';
        this.ctx.fillText(conn.label, midX, midY + 1);
      }

      this.ctx.restore();
    });
  }

  drawNodes() {
    this.nodes.forEach(node => {
      const isActive = this.activeNodeIds.has(node.id);
      const isSelected = this.selectedNode && this.selectedNode.id === node.id;

      this.ctx.save();
      
      this.ctx.fillStyle = isActive ? 'rgba(0, 242, 254, 0.22)' : 'rgba(13, 19, 33, 0.94)';
      this.ctx.strokeStyle = isSelected ? '#00f2fe' : (isActive ? node.color : 'rgba(255, 255, 255, 0.18)');
      this.ctx.lineWidth = isSelected || isActive ? 2.5 : 1;

      if (isSelected || isActive) {
        this.ctx.shadowColor = node.color;
        this.ctx.shadowBlur = 14;
      }

      this.roundRect(node.x, node.y, node.w, node.h, 8, true, true);

      // Accent Dot
      this.ctx.beginPath();
      this.ctx.arc(node.x + 14, node.y + 16, 4.5, 0, Math.PI * 2);
      this.ctx.fillStyle = node.color;
      this.ctx.fill();

      // Label Text with WORD WRAPPING
      this.ctx.font = '700 11px "Inter", sans-serif';
      this.ctx.textBaseline = 'top';
      this.ctx.textAlign = 'left';
      this.ctx.fillStyle = '#ffffff';
      
      const maxTextWidth = node.w - 32;
      const rawLines = node.label.split('\n');
      let currentY = node.y + 12;

      rawLines.forEach((rawLine) => {
        const wrappedSublines = this.wrapText(rawLine, maxTextWidth);
        wrappedSublines.forEach((subline) => {
          this.ctx.fillText(subline, node.x + 26, currentY);
          currentY += 15;
        });
      });

      // Group Footer Tag
      this.ctx.font = '9px "JetBrains Mono", monospace';
      this.ctx.fillStyle = 'rgba(255, 255, 255, 0.45)';
      this.ctx.fillText(node.group, node.x + 10, node.y + node.h - 14);

      this.ctx.restore();
    });
  }

  wrapText(text, maxWidth) {
    if (!text) return [];
    const words = text.split(' ');
    const lines = [];
    let currentLine = words[0];

    for (let i = 1; i < words.length; i++) {
      const word = words[i];
      const width = this.ctx.measureText(currentLine + " " + word).width;
      if (width < maxWidth) {
        currentLine += " " + word;
      } else {
        lines.push(currentLine);
        currentLine = word;
      }
    }
    lines.push(currentLine);
    return lines;
  }

  updateAndDrawParticles() {
    for (let i = this.particles.length - 1; i >= 0; i--) {
      const p = this.particles[i];
      p.progress += p.speed;

      const p1 = p.waypoints[p.waypointIdx];
      const p2 = p.waypoints[p.waypointIdx + 1];

      if (!p1 || !p2) {
        this.particles.splice(i, 1);
        continue;
      }

      const currX = p1.x + (p2.x - p1.x) * p.progress;
      const currY = p1.y + (p2.y - p1.y) * p.progress;

      this.ctx.save();
      this.ctx.beginPath();
      this.ctx.arc(currX, currY, 5.5, 0, Math.PI * 2);
      this.ctx.fillStyle = p.color || '#00f2fe';
      this.ctx.shadowColor = p.color || '#00f2fe';
      this.ctx.shadowBlur = 12;
      this.ctx.fill();
      this.ctx.restore();

      if (p.progress >= 1) {
        p.waypointIdx++;
        p.progress = 0;
        if (p.waypointIdx >= p.waypoints.length - 1) {
          this.particles.splice(i, 1);
        }
      }
    }
  }

  roundRect(x, y, w, h, r, fill, stroke) {
    this.ctx.beginPath();
    this.ctx.moveTo(x + r, y);
    this.ctx.arcTo(x + w, y, x + w, y + h, r);
    this.ctx.arcTo(x + w, y + h, x, y + h, r);
    this.ctx.arcTo(x, y + h, x, y, r);
    this.ctx.arcTo(x, y, x + w, y, r);
    this.ctx.closePath();
    if (fill) this.ctx.fill();
    if (stroke) this.ctx.stroke();
  }
}

window.addEventListener('DOMContentLoaded', () => {
  window.app = new ArchitectureApp();
});
