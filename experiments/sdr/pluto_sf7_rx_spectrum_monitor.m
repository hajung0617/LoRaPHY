function pluto_sf7_rx_spectrum_monitor
% Receive numbered SF7 LoRaPHY packets while showing a live Pluto PSD view.
% One Pluto receiver stream feeds both the decoder and the spectrum display.
% PSD is relative to normalized complex full scale (dBFS/Hz), not calibrated dBm.

scriptDir = fileparts(mfilename('fullpath'));
projectDir = fileparts(fileparts(scriptDir));
addpath(projectDir);

cfg.RadioID = 'sn:1044739a470b00071c001400d59c7fc707';
cfg.CenterFrequency = 263e6;
cfg.LoRaSF = 7;
cfg.LoRaBW = 125e3;
cfg.CodingRate = 1;
cfg.SampleRate = 2e6;          % Shared IQ rate for PSD and LoRa decoding.
cfg.SamplesPerFrame = 65536;   % 32.768 ms per receive call at 2 MS/s.
cfg.GainSource = 'AGC Slow Attack';
cfg.ManualGain = 30;           % Used only when GainSource is 'Manual'.
cfg.FFTSize = 8192;
cfg.PlotSpan_Hz = 2e6;          % Display +/- 1 MHz around the RF center.
cfg.ThresholdAboveFloor_dB = 10;
cfg.WaterfallRows = 300;
cfg.PlotUpdatePeriod_s = 0.10;
cfg.LogPeriod_s = 0.25;
cfg.ExpectedPackets = 100;
cfg.PayloadBytes = 16;
cfg.StartTimeout_s = 180;
cfg.IdleTimeout_s = 20;
cfg.RxBufferSeconds = 2;
cfg.DecodeInterval_s = 0.5;
cfg.OutputDir = fullfile(projectDir,'experiments','results','sdr');

if cfg.CenterFrequency < 325e6 || cfg.CenterFrequency > 3.8e9
    warning('PlutoMonitor:OutsideQualifiedRange', ...
        'The selected center frequency is outside the Pluto 325 MHz-3.8 GHz qualified range.');
end
if ~exist(cfg.OutputDir,'dir'), mkdir(cfg.OutputDir); end
stamp = char(datetime('now','Format','yyyyMMdd_HHmmss_SSS'));
freqTag = sprintf('%gMHz_',cfg.CenterFrequency/1e6);
measurementFile = fullfile(cfg.OutputDir,[freqTag 'combined_measurements_' stamp '.csv']);
eventFile = fullfile(cfg.OutputDir,[freqTag 'combined_events_' stamp '.csv']);
resultFile = fullfile(cfg.OutputDir,[freqTag 'sf7_rx_summary_' stamp '.csv']);

% Verify the selected receiver is visible in this MATLAB session.
availableRadios = findPlutoRadio;
availableIds = {availableRadios.RadioID};
availableSerialIds = {};
if isfield(availableRadios,'SerialNum')
    availableSerialIds = cellfun(@(serial) ['sn:' serial], ...
        {availableRadios.SerialNum},'UniformOutput',false);
end
if ~any(strcmp(cfg.RadioID,availableIds)) && ~any(strcmp(cfg.RadioID,availableSerialIds))
    error('PlutoCombined:RadioNotFound', ...
        'Receiver %s is not visible. Check its serial number and release it from other MATLAB sessions.', ...
        cfg.RadioID);
end

rxArgs = {'RadioID',cfg.RadioID, ...
    'CenterFrequency',cfg.CenterFrequency, ...
    'BasebandSampleRate',cfg.SampleRate, ...
    'SamplesPerFrame',cfg.SamplesPerFrame, ...
    'OutputDataType','double', ...
    'GainSource',cfg.GainSource};
if strcmpi(cfg.GainSource,'Manual')
    rxArgs = [rxArgs, {'Gain',cfg.ManualGain}];
    gainRecordDb = cfg.ManualGain;
else
    gainRecordDb = NaN;
end
rx = sdrrx('Pluto',rxArgs{:});
rxCleanup = onCleanup(@()release(rx)); %#ok<NASGU>
[~,~,initialOverflow] = rx();
overflowCount = double(initialOverflow);
actual = info(rx);
disp(actual);
phy = LoRaPHY(cfg.CenterFrequency,cfg.LoRaSF,cfg.LoRaBW,actual.BasebandSampleRate);
phy.has_header = 1;
phy.cr = cfg.CodingRate;
phy.crc = 1;
phy.preamble_len = 8;
fprintf('Listening at %.6f MHz, SF%d, BW %.0f kHz, gain mode %s.\n', ...
    actual.CenterFrequency/1e6,cfg.LoRaSF,cfg.LoRaBW/1e3,cfg.GainSource);
fprintf('Start pluto_sf7_100_tx.m now; receiver and monitor are ready.\n');

fs = actual.BasebandSampleRate;
if cfg.PlotSpan_Hz <= 0 || cfg.PlotSpan_Hz > fs
    error('PlotSpan_Hz must be positive and no greater than the actual sample rate.');
end
nfft = cfg.FFTSize;
if nfft > cfg.SamplesPerFrame || mod(cfg.SamplesPerFrame,nfft) ~= 0
    error('FFTSize must divide SamplesPerFrame and be no larger than it.');
end
win = hann(nfft,'periodic');
windowPower = sum(win.^2);
hop = nfft/2;
freq = actual.CenterFrequency + (-nfft/2:nfft/2-1)'*(fs/nfft);
keep = freq >= actual.CenterFrequency-cfg.PlotSpan_Hz/2 & ...
    freq <= actual.CenterFrequency+cfg.PlotSpan_Hz/2;
freqMHz = freq(keep)/1e6;
channel = abs(freq-actual.CenterFrequency) <= cfg.LoRaBW/2;
channel = channel(keep);
centerMHz = actual.CenterFrequency/1e6;
halfSpanMHz = cfg.PlotSpan_Hz/(2e6);
halfChannelMHz = cfg.LoRaBW/(2e6);

fig = figure('Name',sprintf('Pluto SF%d RX + PSD | %.6f MHz', ...
    cfg.LoRaSF,centerMHz),'NumberTitle','off','Color','w', ...
    'CloseRequestFcn',@stopMonitor);
stopRequested = false;
uicontrol(fig,'Style','pushbutton','String','Stop','Units','normalized', ...
    'Position',[.90 .94 .08 .045],'Callback',@stopMonitor);
uicontrol(fig,'Style','text','String','Threshold above floor (dB)', ...
    'Units','normalized','Position',[.55 .94 .20 .04],'BackgroundColor','w');
thresholdBox = uicontrol(fig,'Style','edit', ...
    'String',num2str(cfg.ThresholdAboveFloor_dB), ...
    'Units','normalized','Position',[.76 .945 .09 .035]);
avgBox = uicontrol(fig,'Style','checkbox','String','Time average','Value',1, ...
    'Units','normalized','Position',[.02 .94 .15 .04], ...
    'BackgroundColor','w','Callback',@toggleAverage);
maxBox = uicontrol(fig,'Style','checkbox','String','Max hold','Value',1, ...
    'Units','normalized','Position',[.18 .94 .12 .04], ...
    'BackgroundColor','w','Callback',@toggleMaxHold);
statusText = uicontrol(fig,'Style','text','String','CRC OK: 0/100', ...
    'Units','normalized','Position',[.32 .94 .21 .04], ...
    'BackgroundColor','w','HorizontalAlignment','left');

ax1 = subplot(2,1,1,'Parent',fig);
hold(ax1,'on'); grid(ax1,'on');
hNow = plot(ax1,freqMHz,nan(size(freqMHz)),'b');
hAvg = plot(ax1,freqMHz,nan(size(freqMHz)),'r','LineWidth',1.1);
hMax = plot(ax1,freqMHz,nan(size(freqMHz)),'Color',[.4 .4 .4]);
patch(ax1,[centerMHz-halfChannelMHz centerMHz+halfChannelMHz ...
    centerMHz+halfChannelMHz centerMHz-halfChannelMHz],[-200 -200 20 20], ...
    [1 .85 .75],'FaceAlpha',.25,'EdgeColor','none','HandleVisibility','off');
uistack(hNow,'top'); uistack(hAvg,'top'); uistack(hMax,'top');
xlim(ax1,[centerMHz-halfSpanMHz centerMHz+halfSpanMHz]);
xlabel(ax1,'Frequency (MHz)'); ylabel(ax1,'PSD (dBFS/Hz)');
title(ax1,sprintf('Live PSD | center %.6f MHz | RX gain: %s', ...
    centerMHz,cfg.GainSource));
legend(ax1,{'Current PSD','Time average PSD','Max hold'},'Location','best');

ax2 = subplot(2,1,2,'Parent',fig);
wf = nan(cfg.WaterfallRows,sum(keep),'single');
hImg = imagesc(ax2,freqMHz,1:cfg.WaterfallRows,wf);
axis(ax2,'xy'); xlim(ax2,[centerMHz-halfSpanMHz centerMHz+halfSpanMHz]);
xlabel(ax2,'Frequency (MHz)'); ylabel(ax2,'Recent frames');
title(ax2,'Waterfall (color: dBFS/Hz)'); colorbar(ax2);

meas = fopen(measurementFile,'w');
evlog = fopen(eventFile,'w');
assert(meas~=-1 && evlog~=-1,'Cannot create combined monitor output files.');
closeFiles = onCleanup(@()closeLogs(meas,evlog)); %#ok<NASGU>
fprintf(meas,['timestamp,requested_center_Hz,actual_center_Hz,actual_fs_Hz,' ...
    'gain_source,manual_gain_dB,peak_freq_Hz,peak_psd_dBFS_Hz,' ...
    'channel_peak_dBFS_Hz,channel_mean_dBFS_Hz,threshold_dB,' ...
    'detected_count,crc_ok_packets,rx_overflow_reports\n']);
fprintf(evlog,['start_time,end_time,center_freq_Hz,bandwidth_Hz,max_psd_dBFS_Hz,' ...
    'max_excess_dB,duration_s,overlaps_LoRa_channel,classification\n']);

received = false(cfg.ExpectedPackets,1);
rxBuffer = complex(zeros(0,1));
maxBufferSamples = round(cfg.RxBufferSeconds*fs);
lastDecode = tic;
lastDraw = tic;
lastLog = tic;
listenTimer = tic;
lastValidPacketTime = [];
avgPower = zeros(sum(keep),1);
maxPower = -inf(sum(keep),1);
avgCount = 0;
wfRow = 0;
active = struct('fc',{},'bw',{},'maxP',{},'maxExcess',{}, ...
    'start',{},'last',{},'hits',{});

while ~stopRequested && isvalid(fig) && toc(listenTimer)<cfg.StartTimeout_s
    if ~isempty(lastValidPacketTime) && ...
            toc(lastValidPacketTime)>=cfg.IdleTimeout_s
        fprintf('No CRC-valid packet for %.1f s; ending reception.\n',cfg.IdleTimeout_s);
        break;
    end
    [frame,~,overflow] = rx();
    overflowCount = overflowCount + double(overflow);
    frame = double(frame(:));
    rxBuffer = [rxBuffer; frame]; %#ok<AGROW>
    if numel(rxBuffer)>maxBufferSamples
        rxBuffer = rxBuffer(end-maxBufferSamples+1:end);
    end

    % PSD and waterfall are calculated from this same frame used by the RX buffer.
    nseg = floor((numel(frame)-nfft)/hop)+1;
    p = zeros(nfft,1);
    for s=1:nseg
        ix=(s-1)*hop+(1:nfft);
        X=fftshift(fft(frame(ix).*win,nfft));
        p=p+(abs(X).^2)/(fs*windowPower);
    end
    p=p/max(nseg,1);
    psd=10*log10(max(p,realmin));
    psdBand=psd(keep);
    floorDb=movmedian(psdBand,101,'Endpoints','shrink');
    threshold=str2double(get(thresholdBox,'String'));
    if ~isfinite(threshold) || threshold<0
        threshold=cfg.ThresholdAboveFloor_dB;
    end
    mask=fillShortGaps((psdBand-floorDb)>=threshold,2);
    clusters=maskToClusters(mask,freqMHz,psdBand-floorDb,psdBand);
    nowT=datetime('now','Format','yyyy-MM-dd HH:mm:ss.SSS');
    active=updateEvents(active,clusters,posixtime(nowT),evlog, ...
        cfg.LoRaBW,actual.CenterFrequency);
    avgCount=avgCount+1;
    avgPower=avgPower+(10.^(psdBand/10)-avgPower)/avgCount;
    maxPower=max(maxPower,10.^(psdBand/10));
    wfRow=mod(wfRow,cfg.WaterfallRows)+1;
    wf(wfRow,:)=single(psdBand);

    if toc(lastDecode)>=cfg.DecodeInterval_s
        lastDecode=tic;
        try
            [symbolsRx,~]=phy.demodulate(rxBuffer);
            if ~isempty(symbolsRx)
                [decoded,checksum]=phy.decode(symbolsRx);
                for col=1:size(decoded,2)
                    if size(decoded,1)<cfg.PayloadBytes+2 || isempty(checksum)
                        continue;
                    end
                    payload=uint8(decoded(1:cfg.PayloadBytes,col));
                    receivedCrc=uint8(decoded(cfg.PayloadBytes+1:cfg.PayloadBytes+2,col));
                    expectedCrc=uint8(checksum(:,min(col,size(checksum,2))));
                    if ~isequal(receivedCrc(:),expectedCrc(:)) || ...
                            ~isequal(payload(1:3).',uint8('S7T'))
                        continue;
                    end
                    packetIdx=1+double(payload(4))+256*double(payload(5));
                    if packetIdx>=1 && packetIdx<=cfg.ExpectedPackets && ~received(packetIdx)
                        received(packetIdx)=true;
                        lastValidPacketTime=tic;
                    end
                end
            end
        catch
            % Partial or noisy buffers are expected between complete packets.
        end
        packetCount=nnz(received);
        if packetCount>0
            set(statusText,'String',sprintf('CRC OK: %d/%d', ...
                packetCount,cfg.ExpectedPackets));
        end
        if packetCount==cfg.ExpectedPackets
            fprintf('All %d packets received with valid CRC.\n',cfg.ExpectedPackets);
            break;
        end
    end

    if toc(lastLog)>=cfg.LogPeriod_s
        [~,ip]=max(psdBand);
        ch=psd(channel);
        chMean=10*log10(mean(10.^(ch/10)));
        fprintf(meas,['%s,%.0f,%.0f,%.3f,"%s",%.1f,%.3f,%.3f,' ...
            '%.3f,%.3f,%.1f,%d,%d,%d\n'], ...
            char(nowT),cfg.CenterFrequency,actual.CenterFrequency,fs, ...
            cfg.GainSource,gainRecordDb,freqMHz(ip)*1e6,psdBand(ip), ...
            max(ch),chMean,threshold,numel(clusters),nnz(received),overflowCount);
        lastLog=tic;
    end

    if toc(lastDraw)>=cfg.PlotUpdatePeriod_s && isvalid(fig)
        set(hNow,'YData',psdBand);
        set(hAvg,'YData',10*log10(max(avgPower,realmin)));
        set(hMax,'YData',10*log10(max(maxPower,realmin)));
        set(hImg,'CData',wf);
        set(ax2,'YLim',[1 cfg.WaterfallRows]);
        drawnow limitrate;
        lastDraw=tic;
    end
end

active=updateEvents(active,[],posixtime(datetime('now')),evlog, ...
    cfg.LoRaBW,actual.CenterFrequency,true);
receivedCount=nnz(received);
missingIds=find(~received).';
prrPercent=100*receivedCount/cfg.ExpectedPackets;
results=table(cfg.LoRaSF,cfg.LoRaBW/1e3,cfg.ExpectedPackets,receivedCount, ...
    prrPercent,overflowCount,string(strjoin(string(missingIds),';')), ...
    'VariableNames',{'SF','Bandwidth_kHz','Sent','CRC_OK','PRR_percent', ...
    'RX_overflow_reports','MissingPacketIDs'});
writetable(results,resultFile);
disp(results);
fprintf('Measurements: %s\nEvents: %s\nRX summary: %s\n', ...
    measurementFile,eventFile,resultFile);
release(rx);

    function stopMonitor(~,~)
        stopRequested=true;
        if isvalid(fig)
            set(fig,'CloseRequestFcn','');
            delete(fig);
        end
    end

    function toggleAverage(~,~)
        if get(avgBox,'Value'), set(hAvg,'Visible','on');
        else, set(hAvg,'Visible','off'); end
    end

    function toggleMaxHold(~,~)
        if get(maxBox,'Value'), set(hMax,'Visible','on');
        else, set(hMax,'Visible','off'); end
    end
end

function clusters=maskToClusters(mask,freqMHz,excess,power)
edges=diff([false;mask(:);false]);
starts=find(edges==1);
stops=find(edges==-1)-1;
clusters=struct('fc',{},'bw',{},'maxP',{},'maxExcess',{});
for k=1:numel(starts)
    ix=starts(k):stops(k);
    [mp,j]=max(power(ix));
    clusters(k).fc=freqMHz(ix(j))*1e6;
    clusters(k).bw=numel(ix)*(freqMHz(2)-freqMHz(1))*1e6;
    clusters(k).maxP=mp;
    clusters(k).maxExcess=max(excess(ix));
end
end

function mask=fillShortGaps(mask,maxGap)
mask=mask(:);
z=diff([true;mask;true]);
a=find(z==-1);
b=find(z==1)-1;
for k=1:numel(a)
    if b(k)-a(k)+1<=maxGap, mask(a(k):b(k))=true; end
end
end

function active=updateEvents(active,c,t,fh,bwCh,center,flush)
if nargin<7, flush=false; end
for j=1:numel(c)
    if isempty(active)
        ix=[];
    else
        ix=find(abs([active.fc]-c(j).fc)<max(2*c(j).bw,20e3),1);
    end
    if isempty(ix)
        e=struct('fc',c(j).fc,'bw',c(j).bw,'maxP',c(j).maxP, ...
            'maxExcess',c(j).maxExcess,'start',t,'last',t,'hits',1);
        active(end+1)=e; %#ok<AGROW>
    else
        active(ix).fc=c(j).fc;
        active(ix).bw=max(active(ix).bw,c(j).bw);
        active(ix).maxP=max(active(ix).maxP,c(j).maxP);
        active(ix).maxExcess=max(active(ix).maxExcess,c(j).maxExcess);
        active(ix).last=t;
        active(ix).hits=active(ix).hits+1;
    end
end
for k=numel(active):-1:1
    if flush || t-active(k).last>1.0
        dur=max(active(k).last-active(k).start,0);
        overlap=abs(active(k).fc-center)<=(active(k).bw+bwCh)/2;
        if active(k).hits>=4 && dur>=1.0, label='persistent';
        else, label='intermittent'; end
        t0=char(datetime(active(k).start,'ConvertFrom','posixtime', ...
            'Format','yyyy-MM-dd HH:mm:ss.SSS'));
        t1=char(datetime(active(k).last,'ConvertFrom','posixtime', ...
            'Format','yyyy-MM-dd HH:mm:ss.SSS'));
        fprintf(fh,'"%s","%s",%.0f,%.0f,%.2f,%.2f,%.3f,%d,%s\n', ...
            t0,t1,active(k).fc,active(k).bw,active(k).maxP, ...
            active(k).maxExcess,dur,overlap,label);
        active(k)=[];
    end
end
end

function closeLogs(a,b)
if a~=-1, fclose(a); end
if b~=-1, fclose(b); end
end
