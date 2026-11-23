%% Assumption-based LoRa PHY PRR estimate (MATLAB R2024b)
% Reads existing link RSS; does not rerun or alter the Ray Tracing analysis.
% PRR is a conditional AWGN scenario estimate, not a campus measurement.

rootDir = fileparts(fileparts(mfilename("fullpath")));
outDir = fullfile(rootDir,"simulation","results");
cfg.sf = 7;
cfg.bandwidthHz = 125e3;
cfg.codeRate = "4/5";
cfg.payloadBytes = 20;
cfg.noiseFigure_dB = 6;
cfg.assumedInterferencePower_dBm = -65; % deliberately strong scenario assumption
cfg.preambleSymbols = 6;                % LoRaPHY.m constructor default
cfg.randomSeed = 20261117;
cfg.snrGrid_dB = -10:1:-4;
cfg.packetsPerSNR = 100;                % Monte Carlo packets per curve point

rssFile = fullfile(outDir,"building_rss_values.csv");
nodeFile = fullfile(outDir,"node_positions.csv");
osmFile = fullfile(rootDir,"data","simulation","raw","map.osm");
assert(isfile(rssFile) && isfile(nodeFile) && isfile(osmFile), ...
    "Required RSS, node, or OSM input is missing.");
assert(isfile(fullfile(rootDir,"LoRaPHY.m")),"LoRaPHY.m is missing.");

R = readtable(rssFile,TextType="string");
nodeOpts=detectImportOptions(nodeFile,TextType="string");
nodeOpts=setvartype(nodeOpts,"OSM_ID","string");
nodes=readtable(nodeFile,nodeOpts);
thermalNoise_dBm = -174 + 10*log10(cfg.bandwidthHz) + cfg.noiseFigure_dB;
totalNoise_dBm = 10*log10(10^(thermalNoise_dBm/10) + ...
    10^(cfg.assumedInterferencePower_dBm/10));
R.EffectiveNoise_dBm = repmat(totalNoise_dBm,height(R),1);
R.LinkSNR_dB = R.RSS_dBm - R.EffectiveNoise_dBm;

% Build a receiver-level PER curve with the repository's full LoRa PHY.
addpath(rootDir);
phy = LoRaPHY(263e6,cfg.sf,cfg.bandwidthHz,2*cfg.bandwidthHz);
phy.cr = 1;                 % LoRaPHY encoding index for CR 4/5
phy.has_header = 1;
phy.crc = 1;
phy.preamble_len = cfg.preambleSymbols;
phy.payload_len = cfg.payloadBytes;
phy.fast_mode = false;
rng(cfg.randomSeed,"twister");

oldWarningState = warning;
warning("off","all");
warningCleanup = onCleanup(@() warning(oldWarningState)); %#ok<NASGU>
curveTx = zeros(numel(cfg.snrGrid_dB),1);
curveRx = zeros(numel(cfg.snrGrid_dB),1);
curvePRR = zeros(numel(cfg.snrGrid_dB),1);
fs = 2*cfg.bandwidthHz;

for si = 1:numel(cfg.snrGrid_dB)
    targetSNR = cfg.snrGrid_dB(si);
    for trial = 1:cfg.packetsPerSNR
        % decode() parses the received explicit header and mutates cr/CRC
        % fields, including on a corrupted packet. Restore transmitter setup.
        phy.cr = 1;
        phy.has_header = 1;
        phy.crc = 1;
        phy.payload_len = cfg.payloadBytes;
        phy.preamble_len = cfg.preambleSymbols;
        payload = uint8(randi([0 255],cfg.payloadBytes,1));
        txSymbols = phy.encode(payload);
        txWaveform = phy.modulate(txSymbols);
        noise = randn(size(txWaveform)) + 1i*randn(size(txWaveform));
        % Calibrate white noise after the same receiver-bandwidth filter used
        % by LoRaPHY.demodulate, so targetSNR is an in-band SNR in dB.
        txInBand = lowpass(txWaveform,cfg.bandwidthHz/2,fs);
        noiseInBand = lowpass(noise,cfg.bandwidthHz/2,fs);
        scale = sqrt(mean(abs(txInBand).^2) / ...
            (mean(abs(noiseInBand).^2)*10^(targetSNR/10)));
        rxWaveform = txWaveform + scale*noise;
        curveTx(si) = curveTx(si) + 1;
        try
            [rxSymbols,~,~] = phy.demodulate(rxWaveform);
            if isempty(rxSymbols), continue; end
            [rxBytes,calculatedCRC] = phy.decode(rxSymbols(:,1));
            hasPayloadAndCRC = numel(rxBytes) >= cfg.payloadBytes+2;
            if ~hasPayloadAndCRC, continue; end
            payloadOK = isequal(rxBytes(1:cfg.payloadBytes),payload);
            crcOK = isequal(rxBytes(end-1:end),calculatedCRC(:));
            if payloadOK && crcOK
                curveRx(si) = curveRx(si) + 1;
            end
        catch
            % Sync, header, decoding, and CRC failures count as lost packets.
        end
    end
    curvePRR(si) = curveRx(si)/curveTx(si);
    fprintf("AWGN curve %+.0f dB: %d/%d packets, PRR %.1f%%\n", ...
        targetSNR,curveRx(si),curveTx(si),100*curvePRR(si));
end

% Suppress finite-sample non-monotonic bumps before interpolation.
for si = 2:numel(curvePRR)
    curvePRR(si) = max(curvePRR(si),curvePRR(si-1));
end
curve = table(cfg.snrGrid_dB(:),curveTx,curveRx, ...
    100*curvePRR(:),100*(1-curvePRR(:)), ...
    'VariableNames',{'SNR_dB','PacketsTransmitted','PacketsReceived', ...
    'PRR_percent','PER_percent'});
writetable(curve,fullfile(outDir,"prr_awgn_curve.csv"));

R.Estimated_PRR_percent = NaN(height(R),1);
for ri = 1:height(R)
    if ~isfinite(R.LinkSNR_dB(ri)) || ~isfinite(R.RSS_dBm(ri)), continue; end
    p = interp1(cfg.snrGrid_dB,curvePRR,R.LinkSNR_dB(ri),"linear",NaN);
    if R.LinkSNR_dB(ri) < cfg.snrGrid_dB(1), p = 0; end
    if R.LinkSNR_dB(ri) > cfg.snrGrid_dB(end), p = curvePRR(end); end
    R.Estimated_PRR_percent(ri) = 100*min(1,max(0,p));
end
R.PRR_Model = repmat("LoRaPHY AWGN Monte Carlo; assumed -70 dBm in-band interference",height(R),1);
writetable(R,fullfile(outDir,"prr_link_results.csv"));

% Summary by receiver class and frequency.
freqs = sort(unique(R.Frequency_Hz));
kinds = ["rooftop";"indoor_virtual"];
NodeType = strings(numel(freqs)*numel(kinds),1);
Frequency_Hz = zeros(size(NodeType));
MeanPRR_percent = NaN(size(NodeType));
MedianPRR_percent = NaN(size(NodeType));
row = 0;
for ki = 1:numel(kinds)
    for fi = 1:numel(freqs)
        row = row+1; NodeType(row)=kinds(ki); Frequency_Hz(row)=freqs(fi);
        ix=R.NodeType==kinds(ki) & R.Frequency_Hz==freqs(fi) & ...
            isfinite(R.Estimated_PRR_percent);
        MeanPRR_percent(row)=mean(R.Estimated_PRR_percent(ix));
        MedianPRR_percent(row)=median(R.Estimated_PRR_percent(ix));
    end
end
summary=table(NodeType,Frequency_Hz,MeanPRR_percent,MedianPRR_percent);
writetable(summary,fullfile(outDir,"prr_summary.csv"));

% Four-panel plan-view map: entire OSM building footprint colored by PRR.
osm=readgeotable(osmFile,Layer="buildings");
fig=figure(Name="PRR scenario maps",Color="w",Position=[60 60 1920 1060]);
tl=tiledlayout(fig,2,2,TileSpacing="compact",Padding="compact");
% Traffic-light scale: low PRR red, middle yellow, high green.
prrAnchors=[0.82 0.12 0.16; 1.00 0.82 0.08; 0.10 0.62 0.28];
cmap=interp1([0 0.5 1],prrAnchors,linspace(0,1,256));
prrDisplayLimits=[60 100];
tx=nodes(nodes.NodeType=="transmitter",:);
for ki=1:numel(kinds)
    sub=nodes(nodes.NodeType==kinds(ki),:);
    for fi=1:numel(freqs)
        ax=geoaxes(tl); ax.Layout.Tile=(ki-1)*2+fi; hold(ax,"on");
        try, ax.Toolbar.Visible="off"; catch, end
        for ni=1:height(sub)
            ri=find(R.NodeID==sub.NodeID(ni) & R.Frequency_Hz==freqs(fi),1);
            % Prefer the full OSM feature ID (relations may be stored as a
            % composite ID); fall back to matching individual member ways.
            osmId=strtrim(string(sub.OSM_ID(ni)));
            ois=find(strtrim(string(osm.ID))==osmId);
            if isempty(ois)
                osmIds=split(osmId,":");
                ois=find(ismember(strtrim(string(osm.ID)),osmIds));
            end
            if isempty(ri)||isempty(ois)||~isfinite(R.Estimated_PRR_percent(ri)), continue; end
            p=R.Estimated_PRR_percent(ri);
            ci=max(1,min(256,round(1+255*(p-prrDisplayLimits(1))/(prrDisplayLimits(2)-prrDisplayLimits(1)))));
            for oi=ois(:)'
                geoplot(ax,osm.Shape(oi),FaceColor=cmap(ci,:),FaceAlpha=1.0, ...
                    EdgeColor=[0.1 0.1 0.1],LineStyle="-",LineWidth=0.9);
            end
            name=sub.BuildingName(ni);
            text(ax,sub.Latitude(ni),sub.Longitude(ni),name,FontSize=7, ...
                Color="k",FontWeight="bold",Interpreter="none");
        end
        geoplot(ax,tx.Latitude,tx.Longitude,"p",MarkerSize=11, ...
            MarkerFaceColor="r",MarkerEdgeColor="w");
        try, geobasemap(ax,"streets-light"); catch, geobasemap(ax,"none"); end
        ax.Grid="off"; ax.LatitudeLabel.String=""; ax.LongitudeLabel.String="";
        if kinds(ki)=="rooftop", kindLabel="Rooftop"; else, kindLabel="Virtual indoor"; end
        title(ax,sprintf("%s | %.0f MHz",kindLabel,freqs(fi)/1e6));
        geolimits(ax,[min([sub.Latitude;tx.Latitude])-0.0007 ...
            max([sub.Latitude;tx.Latitude])+0.0007], ...
            [min([sub.Longitude;tx.Longitude])-0.0009 ...
            max([sub.Longitude;tx.Longitude])+0.0009]);
        clim(ax,prrDisplayLimits); colormap(ax,cmap);
    end
end
cb=colorbar; cb.Layout.Tile="east"; cb.Label.String="Estimated PRR (%)"; cb.Limits=prrDisplayLimits; cb.Ticks=60:2:100;
exportgraphics(fig,fullfile(outDir,"prr_node_maps.png"),Resolution=300); close(fig);

% Indoor-only comparison for four selected buildings, styled after reference p.37.
selectedBuildings=[ ...
    string(char([hex2dec("C885") hex2dec("D569") hex2dec("BCF5") hex2dec("C9C0") hex2dec("AD00")])); ... % Welfare
    string(char([hex2dec("BD81") hex2dec("C545") hex2dec("AD00")])); ... % Bugak
    string(char([hex2dec("ACF5") hex2dec("D559") hex2dec("AD00")])); ... % Gonghak
    string(char([hex2dec("ACFC") hex2dec("D559") hex2dec("AD00")]))]; % Gwahak
indoorMeans=NaN(numel(selectedBuildings),numel(freqs));
for bi=1:numel(selectedBuildings)
    for fi=1:numel(freqs)
        ix=R.NodeType=="indoor_virtual" & R.BuildingName==selectedBuildings(bi) & ...
            R.Frequency_Hz==freqs(fi);
        indoorMeans(bi,fi)=mean(R.Estimated_PRR_percent(ix),"omitnan");
    end
end

% Create a fresh figure and chart axes; no chart title is required.
prrCompareFig=figure(Name="Indoor PRR by selected building", ...
    Color="w",Position=[120 100 1600 900]);
ax=axes(prrCompareFig,Position=[0.08 0.17 0.84 0.70]);
hold(ax,"on");
b=bar(ax,indoorMeans,0.88,"grouped");
for fi=1:numel(freqs)
    if freqs(fi)==263e6
        b(fi).FaceColor=[0.12 0.47 0.71]; % blue: 263 MHz
    elseif freqs(fi)==922e6
        b(fi).FaceColor=[0.90 0.40 0.12]; % orange: 922 MHz
    else
        fallbackColors=lines(numel(freqs));
        b(fi).FaceColor=fallbackColors(fi,:);
    end
    b(fi).EdgeColor="w"; b(fi).LineWidth=1;
end
ax.XTick=1:numel(selectedBuildings); ax.XTickLabel=selectedBuildings;
ax.XLim=[0.5 numel(selectedBuildings)+0.5];
ax.FontSize=18; ax.LineWidth=1.1;
ylim(ax,[0 100]); yticks(ax,0:10:100);
ylabel(ax,"Estimated indoor PRR (%)",FontSize=19);
legend(ax,b,compose("%.0f MHz",freqs/1e6),Location="southeast",FontSize=16);

grid(ax,"on"); ax.GridAlpha=0.18; ax.Box="on";
exportgraphics(prrCompareFig,fullfile(outDir,"prr_frequency_comparison.png"),Resolution=300);
close(prrCompareFig);

assumptions=table(["Model";"InterferencePower_dBm";"ThermalNoise_dBm"; ...
    "TotalNoiseFloor_dBm";"SF";"Bandwidth_Hz";"CodeRate";"PayloadBytes"; ...
    "PreambleSymbols";"PacketsPerSNR";"SNR_Grid_dB";"RandomSeed"], ...
    ["LoRaPHY full baseband encode/modulate/demodulate/decode with AWGN"; ...
    string(cfg.assumedInterferencePower_dBm);string(thermalNoise_dBm); ...
    string(totalNoise_dBm);string(cfg.sf);string(cfg.bandwidthHz);cfg.codeRate; ...
    string(cfg.payloadBytes);string(cfg.preambleSymbols);string(cfg.packetsPerSNR); ...
    string(min(cfg.snrGrid_dB))+" to "+string(max(cfg.snrGrid_dB));string(cfg.randomSeed)], ...
    'VariableNames',{'Parameter','Value'});
writetable(assumptions,fullfile(outDir,"prr_awgn_assumptions.csv"));

fprintf("PRR scenario complete: %d receiver-frequency cases. Assumed in-band interference %.1f dBm.\n", ...
    height(R),cfg.assumedInterferencePower_dBm);
disp(summary);



