%% Kookmin University LoRa node placement and link analysis (MATLAB R2024b)
% Existing inputs are read only. All generated files go to this folder.
% Default run stage is placement. Inspect the live Site Viewer first; only
% then set kookminRunStage="analysis" and run this file again.

rootDir = fileparts(fileparts(mfilename("fullpath")));
outDir = fullfile(rootDir,"simulation","results");
if ~isfolder(outDir), mkdir(outDir); end

% User-editable settings. Antenna gains are applied in the link budget.
cfg.frequenciesHz = [263e6 922e6];
cfg.sf = 7;
cfg.bandwidthHz = 125e3;
cfg.codeRate = "4/5";
cfg.payloadBytes = 20;
cfg.txPowerdBm = 14;
cfg.txGain_dBi = 2;
cfg.rxGain_dBi = 2;
cfg.txHeightAGL_m = 1.5;
cfg.rxHeightAGL_m = 1.5;
cfg.indoorFloorNumber = 1;                 % first above-ground floor
cfg.floorHeight_m_assumed = 3.2;
cfg.indoorAntennaHeightAboveFloor_m = 1.5;
cfg.noiseFigure_dB = 6;
cfg.interferencePower_dBm = -Inf;            % noise limited; no interferer
cfg.systemLoss_dB = 0;
cfg.belBuildingType = "traditional";         % assumption, not verified
cfg.belProbabilityNotExceeded = 0.50;        % ITU-R P.2109-2 quantile
cfg.maxReflections = 3;
cfg.maxDiffractions = 1;
cfg.heatmapGridSpacing_m = 50;           % outdoor ray-traced sample lattice
cfg.heatmapInterpolation = "natural";   % visualization between computed samples
cfg.sceneZDatumOffset_m = 46.986752;
cfg.projectedOriginX_m = 955651.673610;
cfg.projectedOriginY_m = 1956970.793633;
cfg.crs = projcrs(5179);
cfg.runStage = "placement";
if evalin("base","exist('kookminRunStage','var')")
    cfg.runStage = string(evalin("base","kookminRunStage"));
end

osmFile = fullfile(rootDir,"data","simulation","raw","map.osm");
demFile = fullfile(rootDir,"data","simulation","raw","37608.img");
matchingFile = fullfile(rootDir,"data","simulation","processed","building_height_matching_v2.csv");
glbFile = fullfile(rootDir,"data","simulation","models","kookmin_campus_terrain_buildings_v2.glb");
stlFile = fullfile(rootDir,"data","simulation","models","kookmin_campus_terrain_buildings_v2.stl");
assert(isfile(osmFile) && isfile(demFile) && isfile(matchingFile) && isfile(glbFile) && isfile(stlFile), ...
    "Required OSM, DEM, matching CSV, or GLB model is missing.");

mapping = readtable(matchingFile,TextType="string",VariableNamingRule="preserve");
osm = readgeotable(osmFile,Layer="buildings");
[osmNodeMap,osmWayMap] = parseOSM(osmFile);
[dem,demRef] = readgeoraster(demFile);
dem = double(dem);
dem(dem == -9999) = NaN;
assert(isequal(demRef.RasterSize,[size(dem,1) size(dem,2)]),"DEM grid/reference size mismatch.");

% The OSM exercise-field polygon is way 432296244. Use its area centroid.
[txX,txY,txLat,txLon] = osmWayCenter(osmNodeMap,osmWayMap,"432296244",cfg);
[txGroundZ,txDemOK] = sampleLocalDEM(txX,txY,dem,demRef,cfg);
assert(txDemOK,"The OSM field center falls on DEM NoData/outside coverage; Tx placement stopped.");
txZ = txGroundZ + cfg.txHeightAGL_m;

% Direct OSM ID joins to the local height-matching data. The library is
% excluded: two candidate OSM footprints exist and its register join is
% explicitly marked verify in the existing matching CSV.
targetIDs = ["172918337";"172246889";"172646936";"172646937"; ...
    "relation_6983647";"172646938";"172246888";"172246892";"172646933"; ...
    "579857196";"172646935";"172246893";"579857197";"470221350"; ...
    "172246894";"432296243";"172536209";"666414587";"672438756"];
requestedNames = ["Engineering Hall";"Bukak Hall";"Main Office";"Welfare Hall"; ...
    "Mirae Hall";"Arts Hall";"Gymnasium";"Law Hall";"Science Hall"; ...
    "Kyeongsang Hall";"Business Hall";"Library";"International Hall"; ...
    "Industry-Academia Cooperation Hall";"Sculpture Hall";"Dormitory"; ...
    "Concert Hall";"Global Center";"Guest House"];
nodeRows=makeNodeRow("","","",0,0,0,NaN,NaN,"",NaN,""," ");
nodeRows(1,:)=[];
auditRows = table(strings(0,1),strings(0,1),strings(0,1),strings(0,1), ...
    'VariableNames',{'RequestedBuilding','OSMName','Status','Reason'});

for k=1:numel(targetIDs)
    mi=find(string(mapping.osm_id)==targetIDs(k),1);
    if isempty(mi) && targetIDs(k)=="relation_6983647"
        mi=find(contains(string(mapping.match_quality),"OSM relation building:levels"),1);
    end
    if isempty(mi)
        auditRows(end+1,:)={requestedNames(k),"","excluded","No matching CSV row for target OSM ID"}; %#ok<AGROW>
        continue
    end
    mappedName=string(mapping.osm_name(mi));
    bi=find(string(osm.Name)==mappedName,1);
    if isempty(bi)
        auditRows(end+1,:)={requestedNames(k),mappedName,"excluded","No OSM building polygon for mapped name"}; %#ok<AGROW>
        continue
    end
    h=double(mapping.height_m(mi));
    hSource=string(mapping.height_source(mi));
    hQuality=string(mapping.match_quality(mi));
    if ~isfinite(h) || h<=0
        auditRows(end+1,:)={requestedNames(k),mappedName,"excluded","No positive height in local matching data"}; %#ok<AGROW>
        continue
    end
    if strcmpi(string(mapping.outside_DEM_coverage(mi)),"True")
        auditRows(end+1,:)={requestedNames(k),mappedName,"excluded","Matching row is flagged outside DEM coverage"}; %#ok<AGROW>
        continue
    end

    % OSM footprint area centroid defines the rooftop and virtual indoor XY.
    c=osm.Centroid(bi);
    [east,north]=projfwd(cfg.crs,c.Latitude,c.Longitude);
    x=east-cfg.projectedOriginX_m;
    y=north-cfg.projectedOriginY_m;
    [groundZ,demOK]=sampleLocalDEM(x,y,dem,demRef,cfg);
    if ~demOK
        auditRows(end+1,:)={requestedNames(k),mappedName,"excluded","Footprint centroid is outside valid DEM data"}; %#ok<AGROW>
        continue
    end
    [radius,radiusOK]=osmBoundaryRadius(string(osm.ID(bi)),osmNodeMap,osmWayMap,cfg,x,y);
    if ~radiusOK
        auditRows(end+1,:)={requestedNames(k),mappedName,"excluded","Could not reconstruct OSM footprint outline"}; %#ok<AGROW>
        continue
    end
    % Conservative exterior reference: point on Tx-facing ray beyond the
    % farthest OSM outline vertex, guaranteeing it is outside this footprint.
    toTx=[txX-x,txY-y]; toTx=toTx/norm(toTx);
    refX=x+toTx(1)*(radius+1);
    refY=y+toTx(2)*(radius+1);
    [refGroundZ,refDEMOK]=sampleLocalDEM(refX,refY,dem,demRef,cfg);
    if ~refDEMOK
        auditRows(end+1,:)={requestedNames(k),mappedName,"excluded","Exterior reference falls on DEM NoData/outside coverage"}; %#ok<AGROW>
        continue
    end
    zRoof=groundZ+h+cfg.rxHeightAGL_m;
    zIndoor=groundZ+(cfg.indoorFloorNumber-1)*cfg.floorHeight_m_assumed+ ...
        cfg.indoorAntennaHeightAboveFloor_m;
    zRef=refGroundZ+(cfg.indoorFloorNumber-1)*cfg.floorHeight_m_assumed+ ...
        cfg.indoorAntennaHeightAboveFloor_m;
    [lat,lon]=projinv(cfg.crs,east,north);
    heightStatus=hSource+"; "+hQuality;
    if contains(lower(hSource),"register")
        heightStatus="register-derived; "+heightStatus;
    else
        heightStatus="assumption; "+heightStatus;
    end
    osmID=string(osm.ID(bi));
    roofRow=makeNodeRow("RX-"+targetIDs(k)+"-ROOF",mappedName,"rooftop", ...
        x,y,zRoof,lat,lon,osmID,h,heightStatus,"OSM footprint centroid; DEM sampled");
    indoorRow=makeNodeRow("RX-"+targetIDs(k)+"-INDOOR",mappedName,"indoor_virtual", ...
        x,y,zIndoor,lat,lon,osmID,h,heightStatus, ...
        "virtual footprint-centroid point; floor and room position assumed");
    indoorRow.OutdoorReferenceX_local_m=refX;
    indoorRow.OutdoorReferenceY_local_m=refY;
    indoorRow.OutdoorReferenceZ_local_m=zRef;
    indoorRow.OutdoorReferenceOffset_m=radius+1;
    if isempty(nodeRows), nodeRows=[roofRow;indoorRow];
    else, nodeRows=[nodeRows;roofRow;indoorRow]; end %#ok<AGROW>
    auditRows(end+1,:)={requestedNames(k),mappedName,"included",heightStatus}; %#ok<AGROW>
end
auditRows(end+1,:)={"Other library candidate","도서관 (OSM 469469746)","excluded", ...
    "Selected 성곡도서관 (OSM 172246893) from register association; small alternate OSM footprint is not the main library"};

txRow=makeNodeRow("TX-FIELD-01","Exercise Field","transmitter",txX,txY,txZ, ...
    txLat,txLon,"OSM way 432296244",NaN,"OSM field polygon center", ...
    "DEM raster sample; configurable antenna height above terrain");
nodes=[txRow;nodeRows];
writetable(nodes,fullfile(outDir,"node_positions.csv"));
writetable(auditRows,fullfile(outDir,"building_audit.csv"));
writeConfig(cfg,outDir);

% Open/reuse the GLB scene, then display actual txsite/rxsite objects.
% No new MATLAB process is launched by this script.
if exist('viewer','var') && isa(viewer,'siteviewer') && isvalid(viewer)
    % clearMap can invalidate the Site Viewer in some R2024b sessions.
    try, clearMap(viewer); catch, end
end
if ~exist('viewer','var') || ~isa(viewer,'siteviewer') || ~isvalid(viewer)
    viewer=siteviewer(SceneModel=glbFile, ...
        Name="Kookmin University LoRa nodes",ShowEdges=false,ShowOrigin=false);
end
txViewer=txsite(CoordinateSystem="cartesian",Name="TX-FIELD-01", ...
    AntennaPosition=[txX;txY;txZ],TransmitterFrequency=cfg.frequenciesHz(1), ...
    TransmitterPower=10.^((cfg.txPowerdBm-30)/10));
show(txViewer,Map=viewer,ShowAntennaHeight=true);
rxSites=cell(height(nodeRows),1);
for k=1:height(nodeRows)
    rxSites{k}=rxsite(CoordinateSystem="cartesian",Name=nodeRows.NodeID(k), ...
        AntennaPosition=[nodeRows.X_local_m(k);nodeRows.Y_local_m(k);nodeRows.Z_local_m(k)]);
    show(rxSites{k},Map=viewer,ShowAntennaHeight=true);
end
drawnow;
assert(numel(rxSites)==height(nodeRows) && height(nodes)==1+height(nodeRows), ...
    "Not all intended Tx/Rx site objects were constructed.");
fprintf("Placement stage: %d Tx, %d Rx; Site Viewer class: %s\n", ...
    1,numel(rxSites),class(viewer));
fprintf("Field center from OSM: lat %.8f, lon %.8f; local XYZ [%.2f %.2f %.2f] m\n", ...
    txLat,txLon,txX,txY,txZ);
fprintf("Review live Site Viewer and node_positions.csv before propagation.\n");

% Presentation figure uses the existing STL mesh and the same generated XYZ.
mesh=stlread(stlFile);
fig=figure(Name="Kookmin LoRa node placement",Color="w",Position=[80 80 1600 900]);
trisurf(mesh.ConnectivityList,mesh.Points(:,1),mesh.Points(:,2),mesh.Points(:,3), ...
    'FaceColor',[0.76 0.79 0.82],'EdgeColor','none','FaceAlpha',0.38);
hold on; axis equal; grid on; view(42,28); camlight headlight; lighting gouraud;
ax=gca; ax.Toolbar.Visible='off';
roof=nodeRows.NodeType=="rooftop";
indoor=nodeRows.NodeType=="indoor_virtual";
scatter3(txX,txY,txZ,130,'p','filled','MarkerFaceColor',[0.90 0.12 0.08], ...
    'MarkerEdgeColor','k','DisplayName','Tx field');
scatter3(nodeRows.X_local_m(roof),nodeRows.Y_local_m(roof),nodeRows.Z_local_m(roof), ...
    65,'o','filled','MarkerFaceColor',[0.05 0.45 0.86],'MarkerEdgeColor','k', ...
    'DisplayName','Rooftop Rx');
scatter3(nodeRows.X_local_m(indoor),nodeRows.Y_local_m(indoor),nodeRows.Z_local_m(indoor), ...
    58,'s','filled','MarkerFaceColor',[0.08 0.66 0.43],'MarkerEdgeColor','k', ...
    'DisplayName','Virtual indoor Rx');
text(txX,txY,txZ+5,"TX-FIELD-01",'FontWeight','bold','Color',[0.55 0 0]);
for k=1:2:height(nodeRows)
    shortID=extractBetween(nodeRows.NodeID(k),"RX-","-ROOF");
    text(nodeRows.X_local_m(k)-5,nodeRows.Y_local_m(k),nodeRows.Z_local_m(k)+3, ...
        nodeRows.BuildingName(k),'FontSize',9,'FontWeight','bold','Interpreter','none');
end
xlim([min([txX;nodeRows.X_local_m])-55,max([txX;nodeRows.X_local_m])+55]);
ylim([min([txY;nodeRows.Y_local_m])-55,max([txY;nodeRows.Y_local_m])+55]);
zlim([min(nodeRows.Z_local_m)-12,max(nodeRows.Z_local_m)+22]);
xlabel('Local X (m)'); ylabel('Local Y (m)'); zlabel('Local Z (m; scene datum)');
title('Kookmin University: 3D LoRa Tx/Rx placement','Interpreter','none');
legend('Location','northwest');
ax.Position=[0.06 0.10 0.62 0.80];
idLines=strings(9,1);
for k=1:2:height(nodeRows)
    rid=extractBetween(nodeRows.NodeID(k),"RX-","-ROOF");
    idLines((k+1)/2)=nodeRows.BuildingName(k)+" | roof "+rid+" | indoor "+rid;
end
panelText="Building / node ID"+newline+join(idLines,newline);
annotation(fig,'textbox',[0.70 0.16 0.28 0.67],'String',char(panelText), ...
    'Interpreter','none','FontSize',12,'VerticalAlignment','top', ...
    'BackgroundColor',[0.97 0.97 0.97],'EdgeColor',[0.7 0.7 0.7]);
exportgraphics(fig,fullfile(outDir,"node_placement_3d.png"),Resolution=300);
fig.Visible='off';

if cfg.runStage=="render"
    resultRows=readtable(fullfile(outDir,"link_results.csv"),TextType="string");
    makeRSSFigures(resultRows,outDir);
    B=makeBuildingRSSValues(resultRows,nodeRows,cfg,outDir);
    makeRSSNodeMapWithEstimates(B,nodeRows,cfg,txX,txY,osm,outDir);
    makeBuildingRSSMaps(B,nodeRows,cfg,txX,txY,osm,outDir);
    fprintf("Rendered RSS maps from existing link_results.csv; no Ray Tracing rerun.\n");
    return
elseif cfg.runStage~="analysis"
    fprintf("\nAfter visually confirming markers, run:\n");
    fprintf('  kookminRunStage = "analysis"; run(fullfile("%s","run_kookmin_lora.m"));\n',outDir);
    return
end

%% Ray-traced outdoor path and statistical indoor BEL stage
rt=propagationModel("raytracing",CoordinateSystem="cartesian", ...
    MaxNumReflections=cfg.maxReflections,MaxNumDiffractions=cfg.maxDiffractions);
resultRows=[];
for fi=1:numel(cfg.frequenciesHz)
    fHz=cfg.frequenciesHz(fi);
    txf=txViewer;
    txf.TransmitterFrequency=fHz;
    for k=1:height(nodeRows)
        row=nodeRows(k,:);
        if row.NodeType=="indoor_virtual"
            % Ray trace to an outdoor reference; add exactly one ITU-R BEL.
            rx=rxsite(CoordinateSystem="cartesian",Name="EXTREF-"+row.NodeID, ...
                AntennaPosition=[row.OutdoorReferenceX_local_m; ...
                row.OutdoorReferenceY_local_m;row.OutdoorReferenceZ_local_m]);
            bel=p2109bel(fHz/1e9,cfg.belProbabilityNotExceeded,cfg.belBuildingType, ...
                atan2d(rx.AntennaPosition(3)-txZ, ...
                hypot(rx.AntennaPosition(1)-txX,rx.AntennaPosition(2)-txY)));
        else
            rx=rxSites{k};
            bel=0;
        end
        d=hypot(hypot(row.X_local_m-txX,row.Y_local_m-txY),row.Z_local_m-txZ);
        dRef=hypot(hypot(rx.AntennaPosition(1)-txX,rx.AntennaPosition(2)-txY), ...
            rx.AntennaPosition(3)-txZ);
        try
            isLOS=los(txf,rx,Map=viewer);
            pl=pathloss(rt,rx,txf,Map=viewer);
            if iscell(pl), pl=pl{1}; end
            % Ray tracing returns one loss per propagation path. Sum path
            % powers (incoherent spatial-average model) to obtain one link loss.
            pl=double(pl(:));
            pl=pl(isfinite(pl));
            if isempty(pl)
                pl=NaN;
                linkStatus="No ray returned with configured ray-tracing limits";
            else
                pl=-10*log10(sum(10.^(-pl/10)));
                linkStatus="Computed";
            end
        catch ME
            warning("Ray-tracing link failed for %s at %.0f MHz: %s",row.NodeID,fHz/1e6,ME.message);
            isLOS=NaN; pl=NaN; linkStatus="Ray tracing error";
        end
        rss=cfg.txPowerdBm+cfg.txGain_dBi+cfg.rxGain_dBi-cfg.systemLoss_dB-pl-bel;
        thermalNoise=-174+10*log10(cfg.bandwidthHz)+cfg.noiseFigure_dB;
        if isfinite(cfg.interferencePower_dBm)
            noise=10*log10(10^(thermalNoise/10)+10^(cfg.interferencePower_dBm/10));
        else
            noise=thermalNoise;
        end
        snr=rss-noise;
        newResult=table(row.NodeID,row.BuildingName,row.NodeType,fHz,d,dRef, ...
            isLOS,pl,bel,pl+bel,rss,snr,NaN,linkStatus, ...
            'VariableNames',{'NodeID','BuildingName','NodeType','Frequency_Hz', ...
            'Distance_m','RaytraceReferenceDistance_m','LOS','PathLoss_dB', ...
            'BuildingEntryLoss_dB','TotalLoss_dB','RSS_dBm','SNR_dB','PRR_percent','LinkStatus'});
        if isempty(resultRows), resultRows=newResult;
        else, resultRows=[resultRows;newResult]; end %#ok<AGROW>
    end
end
writetable(resultRows,fullfile(outDir,"link_results.csv"));
makeRSSFigures(resultRows,outDir);
B=makeBuildingRSSValues(resultRows,nodeRows,cfg,outDir);
makeRSSNodeMapWithEstimates(B,nodeRows,cfg,txX,txY,osm,outDir);
makeBuildingRSSMaps(B,nodeRows,cfg,txX,txY,osm,outDir);
% 3D RSS map intentionally skipped; the current task focuses on the plan view.
fprintf("Analysis complete: %d links. PRR is NaN because no validated SNR-PER model is available.\n",height(resultRows));

%% Local helper functions
function [nodeMap,wayMap]=parseOSM(osmFile)
doc=xmlread(osmFile);
nodes=doc.getElementsByTagName('node');
nodeMap=containers.Map('KeyType','char','ValueType','any');
for i=0:nodes.getLength-1
    nd=nodes.item(i);
    nodeMap(char(nd.getAttribute('id')))= ...
        [str2double(char(nd.getAttribute('lat'))),str2double(char(nd.getAttribute('lon')))];
end
ways=doc.getElementsByTagName('way');
wayMap=containers.Map('KeyType','char','ValueType','any');
for i=0:ways.getLength-1
    way=ways.item(i); nds=way.getElementsByTagName('nd');
    latv=NaN(nds.getLength,1); lonv=latv;
    for j=0:nds.getLength-1
        key=char(nds.item(j).getAttribute('ref'));
        if isKey(nodeMap,key), ll=nodeMap(key); latv(j+1)=ll(1); lonv(j+1)=ll(2); end
    end
    wayMap(char(way.getAttribute('id')))=struct('Lat',latv,'Lon',lonv);
end
end

function [xLocal,yLocal,lat,lon]=osmWayCenter(nodeMap,wayMap,wayID,cfg)
assert(isKey(wayMap,char(wayID)),"OSM field way %s not found.",wayID);
w=wayMap(char(wayID)); valid=isfinite(w.Lat)&isfinite(w.Lon);
[east,north]=projfwd(cfg.crs,w.Lat(valid),w.Lon(valid));
pg=polyshape(east,north,'Simplify',true);
[cx,cy]=centroid(pg);
xLocal=cx-cfg.projectedOriginX_m; yLocal=cy-cfg.projectedOriginY_m;
[lat,lon]=projinv(cfg.crs,cx,cy);
end

function [radius,ok]=osmBoundaryRadius(osmID,nodeMap,wayMap,cfg,cx,cy)
parts=split(osmID,":"); allX=[]; allY=[];
for i=1:numel(parts)
    key=char(parts(i));
    if ~isKey(wayMap,key), continue; end
    w=wayMap(key); valid=isfinite(w.Lat)&isfinite(w.Lon);
    if ~any(valid), continue; end
    [east,north]=projfwd(cfg.crs,w.Lat(valid),w.Lon(valid));
    allX=[allX;east-cfg.projectedOriginX_m]; %#ok<AGROW>
    allY=[allY;north-cfg.projectedOriginY_m]; %#ok<AGROW>
end
ok=~isempty(allX); radius=NaN;
if ok, radius=max(hypot(allX-cx,allY-cy)); end
end

function [zLocal,ok]=sampleLocalDEM(xLocal,yLocal,Z,R,cfg)
x=xLocal+cfg.projectedOriginX_m; y=yLocal+cfg.projectedOriginY_m;
[col,row]=worldToIntrinsic(R,x,y);
ok=isfinite(col)&&isfinite(row)&&col>=1&&col<=size(Z,2)&&row>=1&&row<=size(Z,1);
zLocal=NaN;
if ~ok, return; end
v=interp2(1:size(Z,2),1:size(Z,1),Z,col,row,'linear',NaN);
if ~isfinite(v), ok=false; return; end
zLocal=v-cfg.sceneZDatumOffset_m;
end

function row=makeNodeRow(id,bname,kind,x,y,z,lat,lon,osmID,heightM,heightSource,positionSource)
row=table(string(id),string(bname),string(kind),double(x),double(y),double(z), ...
    double(lat),double(lon),string(osmID),double(heightM),string(heightSource), ...
    string(positionSource),NaN,NaN,NaN,NaN,'VariableNames', ...
    {'NodeID','BuildingName','NodeType','X_local_m','Y_local_m','Z_local_m', ...
    'Latitude','Longitude','OSM_ID','BuildingHeight_m','HeightSource','PositionSource', ...
    'OutdoorReferenceX_local_m','OutdoorReferenceY_local_m', ...
    'OutdoorReferenceZ_local_m','OutdoorReferenceOffset_m'});
end

function L=p2109bel(fGHz,p,type,thetaDeg)
assert(fGHz>=0.08&&fGHz<=100,"ITU-R P.2109-2 frequency is outside model range.");
assert(p>0&&p<1,"BEL probability must be strictly between 0 and 1.");
f=log10(fGHz); type=lower(string(type));
if type=="traditional"
    r=12.64; s=3.72; t=0.96; u=9.6; v=2.0; w=9.1; x=-3.0; y=4.5; z=-2.0;
elseif type=="thermally-efficient"
    r=28.19; s=-3.00; t=8.48; u=13.5; v=3.8; w=27.8; x=-2.9; y=9.4; z=-2.1;
else
    error("Unknown ITU-R P.2109-2 building class: %s",type);
end
Le=0.212*abs(thetaDeg); mu1=r+s*f+t*f^2+Le; sigma1=u+v*f;
mu2=w+x*f; sigma2=y+z*f; q=sqrt(2)*erfinv(2*p-1);
A=q*sigma1+mu1; B=q*sigma2+mu2; C=-3.0;
L=10*log10(10^(A/10)+10^(B/10)+10^(C/10));
end

function writeConfig(cfg,outDir)
names=["Frequencies_Hz";"SF";"Bandwidth_Hz";"CodeRate";"PayloadBytes"; ...
    "TxPower_dBm";"TxGain_dBi";"RxGain_dBi";"TxHeightAGL_m";"RxHeightAGL_m"; ...
    "IndoorFloorNumber";"FloorHeight_m_assumed";"IndoorAntennaHeightAboveFloor_m"; ...
    "NoiseFigure_dB";"InterferencePower_dBm";"SystemLoss_dB";"BEL_Class_assumed"; ...
    "BEL_ProbabilityNotExceeded";"RayTracing_MaxReflections"; ...
    "RayTracing_MaxDiffractions";"PRR_Status"];
values=[join(string(cfg.frequenciesHz),";");string(cfg.sf);string(cfg.bandwidthHz); ...
    cfg.codeRate;string(cfg.payloadBytes);string(cfg.txPowerdBm);string(cfg.txGain_dBi); ...
    string(cfg.rxGain_dBi);string(cfg.txHeightAGL_m);string(cfg.rxHeightAGL_m); ...
    string(cfg.indoorFloorNumber);string(cfg.floorHeight_m_assumed); ...
    string(cfg.indoorAntennaHeightAboveFloor_m);string(cfg.noiseFigure_dB); ...
    string(cfg.interferencePower_dBm);string(cfg.systemLoss_dB);cfg.belBuildingType; ...
    string(cfg.belProbabilityNotExceeded);string(cfg.maxReflections); ...
    string(cfg.maxDiffractions);"Not computed: no validated SF7/BW125kHz/CR4/5 SNR-PER model"];
writetable(table(names,values,'VariableNames',{'Parameter','Value'}), ...
    fullfile(outDir,"simulation_config.csv"));
end

function makeRSSFigures(T,outDir)
finiteRSS=T.RSS_dBm(isfinite(T.RSS_dBm));
commonY=[floor(min(finiteRSS)-4),ceil(max(finiteRSS)+4)];
for kind=["rooftop","indoor_virtual"]
    sub=T(T.NodeType==kind,:); freq=unique(sub.Frequency_Hz);
    buildings=unique(sub.BuildingName,'stable'); x=1:numel(buildings);
    f=figure(Name="RSS comparison",Color="w",Position=[80 80 1600 900]);
    hold on; grid on;
    for fi=1:numel(freq)
        vals=NaN(size(x));
        for bi=1:numel(buildings)
            ix=sub.BuildingName==buildings(bi)&sub.Frequency_Hz==freq(fi);
            if any(ix), vals(bi)=sub.RSS_dBm(find(ix,1)); end
        end
        scatter(x,vals,70,'filled','DisplayName',sprintf('%.0f MHz',freq(fi)/1e6));
    end
    xticks(x); xticklabels(buildings); xtickangle(25);
    ylim(commonY);
    for bi=1:numel(buildings)
        if ~any(isfinite(sub.RSS_dBm(sub.BuildingName==buildings(bi))))
            text(x(bi),commonY(1)+1,'no ray','HorizontalAlignment','center', ...
                'FontSize',8,'Color',[0.55 0.1 0.1]);
        end
    end
    ylabel('RSS (dBm)'); xlabel('OSM building');
    title("Ray-traced RSS, "+kind+" receivers",'Interpreter','none');
    legend('Location','best');
    exportgraphics(f,fullfile(outDir,"rss_"+kind+".png"),Resolution=300);
end
end

function makeRSSNodeMap(T,nodes,cfg,txX,txY,osm,outDir)
% Keep the original RSS node plot; add only flat OSM building outlines.
valid=T(isfinite(T.RSS_dBm),:);
if isempty(valid), return; end
limitsRSS=[floor(min(valid.RSS_dBm)),ceil(max(valid.RSS_dBm))];
fig=figure(Name="RSS node maps",Color="w",Position=[60 60 1920 1080]);
tl=tiledlayout(fig,2,2,"TileSpacing","compact","Padding","compact");
freqs=unique(T.Frequency_Hz,'stable');
for ki=1:2
    if ki==1, kind="rooftop"; typeLabel="Rooftop Rx";
    else, kind="indoor_virtual"; typeLabel="Virtual indoor Rx"; end
    sub=nodes(nodes.NodeType==kind,:);
    for fi=1:numel(freqs)
        r=T(T.NodeType==kind & T.Frequency_Hz==freqs(fi),:);
        [tf,loc]=ismember(sub.NodeID,r.NodeID);
        vals=NaN(height(sub),1); vals(tf)=r.RSS_dBm(loc(tf));
        good=tf & isfinite(vals); bad=tf & ~isfinite(vals);
        ax=geoaxes(tl); ax.Layout.Tile=(ki-1)*2+fi; hold(ax,"on");
        footprintIDs=unique(sub.OSM_ID(sub.OSM_ID~=""));
        footprintMask=ismember(string(osm.ID),footprintIDs);
        geoplot(ax,osm.Shape(footprintMask),'FaceColor','none', ...
            'EdgeColor',[0.50 0.54 0.58], ...
            'LineWidth',0.55,'HandleVisibility','off');
        if any(good)
            geoscatter(ax,sub.Latitude(good),sub.Longitude(good),90,vals(good),"o", ...
                "filled","MarkerEdgeColor","k","LineWidth",1.0);
        end
        if any(bad)
            geoscatter(ax,sub.Latitude(bad),sub.Longitude(bad),75,[0.35 0.35 0.35],"x", ...
                "LineWidth",2);
        end
        [txLat,txLon]=projinv(cfg.crs,txX+cfg.projectedOriginX_m,txY+cfg.projectedOriginY_m);
        geoplot(ax,txLat,txLon,"p","MarkerSize",13,"MarkerFaceColor","r","MarkerEdgeColor","w");
        for ni=find(good(:))'
            text(ax,sub.Latitude(ni),sub.Longitude(ni),sub.BuildingName(ni), ...
                'FontSize',8,'Color',[0.15 0.15 0.15],'FontWeight','bold', ...
                'Interpreter','none','VerticalAlignment','bottom');
        end
        try, geobasemap(ax,'none'); catch, end
        ax.Grid='off';
        title(ax,sprintf("%s | %.0f MHz",typeLabel,freqs(fi)/1e6));
        ax.LatitudeLabel.String=""; ax.LongitudeLabel.String="";
        geolimits(ax,[min([sub.Latitude;txLat])-0.0007 max([sub.Latitude;txLat])+0.0007], ...
            [min([sub.Longitude;txLon])-0.0009 max([sub.Longitude;txLon])+0.0009]);
        clim(ax,limitsRSS); colormap(ax,turbo(256));
    end
end
cb=colorbar; cb.Layout.Tile="east"; cb.Label.String="RSS (dBm)"; cb.Limits=limitsRSS;
sgtitle(tl,"Kookmin campus plan view | receiver RSS with building footprints", ...
    "FontWeight","bold");
exportgraphics(fig,fullfile(outDir,"rss_node_maps.png"),Resolution=300);
close(fig);
end

function makeRSS3DNodeMap(nodes,mesh,dem,demRef,cfg,txX,txY,txZ,txViewer,viewer,outDir)
% Compute a finer grid of actual outdoor ray-traced RSS samples and show it
% in a cropped 3D view over the reused campus mesh. No sample extrapolation.
spacing=25; % meters between virtual outdoor Rx samples
xlimMap=[min([nodes.X_local_m;txX])-35,max([nodes.X_local_m;txX])+35];
ylimMap=[min([nodes.Y_local_m;txY])-35,max([nodes.Y_local_m;txY])+35];
xv=ceil(xlimMap(1)/spacing)*spacing:spacing:floor(xlimMap(2)/spacing)*spacing;
yv=ceil(ylimMap(1)/spacing)*spacing:spacing:floor(ylimMap(2)/spacing)*spacing;
[Xg,Yg]=meshgrid(xv,yv); nGrid=numel(Xg);
freqs=cfg.frequenciesHz; RSS=NaN(nGrid,numel(freqs)); Z=NaN(nGrid,1);
validDEM=false(nGrid,1);
for j=1:nGrid
    [zg,validDEM(j)]=sampleLocalDEM(Xg(j),Yg(j),dem,demRef,cfg);
    if validDEM(j), Z(j)=zg+cfg.rxHeightAGL_m; end
end
rt=propagationModel('raytracing',CoordinateSystem='cartesian', ...
    MaxNumReflections=cfg.maxReflections,MaxNumDiffractions=cfg.maxDiffractions);
for fi=1:numel(freqs)
    tx=txViewer; tx.TransmitterFrequency=freqs(fi);
    fprintf('Detailed 3D RSS grid: %.0f MHz, %d samples at %.0f m spacing.\n', ...
        freqs(fi)/1e6,nGrid,spacing);
    for j=find(validDEM(:))'
        rx=rxsite(CoordinateSystem='cartesian',Name=sprintf('RSSGRID-%d-%d',fi,j), ...
            AntennaPosition=[Xg(j);Yg(j);Z(j)]);
        try
            pl=pathloss(rt,rx,tx,Map=viewer);
            if iscell(pl), pl=pl{1}; end
            pl=double(pl(:)); pl=pl(isfinite(pl));
            if ~isempty(pl)
                pl=-10*log10(sum(10.^(-pl/10)));
                RSS(j,fi)=cfg.txPowerdBm+cfg.txGain_dBi+cfg.rxGain_dBi- ...
                    cfg.systemLoss_dB-pl;
            end
        catch ME
            warning('Grid ray tracing failed at %.0f MHz, point %d: %s', ...
                freqs(fi)/1e6,j,ME.message);
        end
        if mod(j,25)==0, drawnow limitrate; end
    end
end
[lat,lon]=projinv(cfg.crs,Xg(:)+cfg.projectedOriginX_m,Yg(:)+cfg.projectedOriginY_m);
G=table(repmat(freqs(1),nGrid,1),Xg(:),Yg(:),Z,lat,lon,RSS(:,1), ...
    'VariableNames',{'Frequency_Hz','X_local_m','Y_local_m','RxZ_local_m', ...
    'Latitude','Longitude','RSS_dBm'});
G2=table(repmat(freqs(2),nGrid,1),Xg(:),Yg(:),Z,lat,lon,RSS(:,2), ...
    'VariableNames',G.Properties.VariableNames);
writetable([G;G2],fullfile(outDir,'rss_3d_raytrace_grid.csv'));
finiteRSS=RSS(isfinite(RSS));
if isempty(finiteRSS), warning('No valid ray-traced RSS grid results.'); return; end
limitsRSS=[floor(min(finiteRSS)),ceil(max(finiteRSS))];
fig=figure(Name='Detailed 3D Ray-Traced RSS',Color='w',Position=[50 50 1920 1080]);
tl=tiledlayout(fig,1,2,'TileSpacing','compact','Padding','compact');
for fi=1:numel(freqs)
    ax=nexttile; hold(ax,'on');
    trisurf(mesh.ConnectivityList,mesh.Points(:,1),mesh.Points(:,2),mesh.Points(:,3), ...
        'FaceColor',[0.72 0.76 0.80],'EdgeColor','none','FaceAlpha',0.23, ...
        'HandleVisibility','off','Parent',ax);
    ok=isfinite(RSS(:,fi));
    scatter3(ax,Xg(ok),Yg(ok),Z(ok),35,RSS(ok,fi),'filled', ...
        'MarkerEdgeColor',[0.15 0.15 0.15],'LineWidth',0.25);
    scatter3(ax,txX,txY,txZ,135,'p','filled','MarkerFaceColor',[0.95 0.12 0.08], ...
        'MarkerEdgeColor','k');
    text(ax,txX,txY,txZ+6,'Tx','FontWeight','bold','Color',[0.65 0 0]);
    title(ax,sprintf('Outdoor Rx | %.0f MHz | %d m grid | %d/%d valid', ...
        freqs(fi)/1e6,spacing,nnz(ok),nGrid),'FontSize',11);
    xlabel(ax,'Local X (m)'); ylabel(ax,'Local Y (m)'); zlabel(ax,'Elevation (m)');
    xlim(ax,xlimMap); ylim(ax,ylimMap); axis(ax,'vis3d'); grid(ax,'on');
    inView=mesh.Points(:,1)>=xlimMap(1) & mesh.Points(:,1)<=xlimMap(2) & ...
        mesh.Points(:,2)>=ylimMap(1) & mesh.Points(:,2)<=ylimMap(2);
    zlim(ax,[min(mesh.Points(inView,3))-5,max(mesh.Points(inView,3))+10]);
    view(ax,42,35); clim(ax,limitsRSS);
end
cb=colorbar; cb.Layout.Tile='east'; cb.Label.String='RSS (dBm)';
colormap(fig,turbo(256));
sgtitle(tl,'Kookmin campus: detailed 3D RSS','FontWeight','bold','FontSize',15);
exportgraphics(fig,fullfile(outDir,'rss_node_maps_3d.png'),Resolution=300);
close(fig);
end

function makePropagationHeatmaps(nodes,dem,demRef,cfg,txX,txY,txZ,txViewer,osm,viewer,outDir)
% Sample outdoor receiver points across the campus, ray trace each point,
% then interpolate only between valid samples for a continuous display.
spacing=cfg.heatmapGridSpacing_m;
xv=(floor((min([nodes.X_local_m;txX])-spacing)/spacing)*spacing):spacing: ...
    (ceil((max([nodes.X_local_m;txX])+spacing)/spacing)*spacing);
yv=(floor((min([nodes.Y_local_m;txY])-spacing)/spacing)*spacing):spacing: ...
    (ceil((max([nodes.Y_local_m;txY])+spacing)/spacing)*spacing);
[Xg,Yg]=meshgrid(xv,yv);
[latG,lonG]=projinv(cfg.crs,Xg+cfg.projectedOriginX_m,Yg+cfg.projectedOriginY_m);
rt=propagationModel("raytracing",CoordinateSystem="cartesian", ...
    MaxNumReflections=cfg.maxReflections,MaxNumDiffractions=cfg.maxDiffractions);
sampleTables=cell(numel(cfg.frequenciesHz),1);
mapRSS=cell(numel(cfg.frequenciesHz),1);
for fi=1:numel(cfg.frequenciesHz)
    fHz=cfg.frequenciesHz(fi);
    tx=txViewer;
    tx.TransmitterFrequency=fHz;
    plGrid=NaN(size(Xg)); rssGrid=plGrid; snrGrid=plGrid; zGrid=plGrid;
    status=strings(size(Xg)); status(:)="No ray";
    for j=1:numel(Xg)
        [zg,ok]=sampleLocalDEM(Xg(j),Yg(j),dem,demRef,cfg);
        if ~ok
            status(j)="DEM NoData"; continue
        end
        zGrid(j)=zg; rx=rxsite(CoordinateSystem="cartesian", ...
            Name=sprintf("GRID-%03d",j), ...
            AntennaPosition=[Xg(j);Yg(j);zg+cfg.rxHeightAGL_m]);
        try
            pl=pathloss(rt,rx,tx,Map=viewer);
            if iscell(pl), pl=pl{1}; end
            pl=double(pl(:)); pl=pl(isfinite(pl));
            if isempty(pl), continue; end
            pl=-10*log10(sum(10.^(-pl/10)));
            plGrid(j)=pl;
            rssGrid(j)=cfg.txPowerdBm+cfg.txGain_dBi+cfg.rxGain_dBi- ...
                cfg.systemLoss_dB-pl;
            noise=-174+10*log10(cfg.bandwidthHz)+cfg.noiseFigure_dB;
            if isfinite(cfg.interferencePower_dBm)
                noise=10*log10(10^(noise/10)+10^(cfg.interferencePower_dBm/10));
            end
            snrGrid(j)=rssGrid(j)-noise; status(j)="Computed";
        catch ME
            status(j)="Ray tracing error";
            warning("Grid ray tracing failed at %.0f MHz, sample %d: %s", ...
                fHz/1e6,j,ME.message);
        end
    end
    S=table(repmat(fHz,numel(Xg),1),Xg(:),Yg(:),zGrid(:),latG(:),lonG(:), ...
        plGrid(:),rssGrid(:),snrGrid(:),status(:), ...
        'VariableNames',{'Frequency_Hz','X_local_m','Y_local_m', ...
        'GroundZ_local_m','Latitude','Longitude','PathLoss_dB','RSS_dBm', ...
        'SNR_dB','RayStatus'});
    sampleTables{fi}=S; mapRSS{fi}=rssGrid;
    fprintf('Outdoor heatmap rays: %.0f MHz, %d samples, %d computed.\n', ...
        fHz/1e6,numel(Xg),sum(isfinite(rssGrid(:))));
end
sampleTable=vertcat(sampleTables{:});
writetable(sampleTable,fullfile(outDir,"propagation_grid_samples.csv"));
allRSS=sampleTable.RSS_dBm(isfinite(sampleTable.RSS_dBm));
if numel(allRSS)<3
    warning("Not enough valid ray-tracing grid samples to create RSS heatmaps.");
    return
end
limitsRSS=[floor(min(allRSS)),ceil(max(allRSS))];
xq=linspace(min(xv),max(xv),220); yq=linspace(min(yv),max(yv),150);
[Xq,Yq]=meshgrid(xq,yq);
[latQ,lonQ]=projinv(cfg.crs,Xq+cfg.projectedOriginX_m,Yq+cfg.projectedOriginY_m);
fig=figure(Name="Ray-traced outdoor RSS heatmaps",Color="w", ...
    Position=[60 60 1800 900]);
tlo=tiledlayout(fig,1,2,"TileSpacing","compact","Padding","compact");
interpolatedTables=cell(numel(cfg.frequenciesHz),1);
for fi=1:numel(cfg.frequenciesHz)
    ax=geoaxes(tlo); ax.Layout.Tile=fi; hold(ax,"on");
    geoplot(ax,osm.Shape,'FaceColor',[0.92 0.92 0.92],'FaceAlpha',0.12, ...
        'EdgeColor',[0.28 0.31 0.35],'LineWidth',0.35);
    finite=isfinite(mapRSS{fi});
    F=scatteredInterpolant(Xg(finite),Yg(finite),mapRSS{fi}(finite), ...
        cfg.heatmapInterpolation,'nearest');
    Zq=F(Xq,Yq);
    ix=max(1,min(numel(xv),round((Xq-xv(1))/spacing)+1));
    iy=max(1,min(numel(yv),round((Yq-yv(1))/spacing)+1));
    nearestOK=finite(sub2ind(size(finite),iy,ix));
    ok=isfinite(Zq);
    geoscatter(ax,latQ(ok),lonQ(ok),160,Zq(ok),'filled', ...
        'MarkerFaceAlpha',0.62,'MarkerEdgeAlpha',0);
    bad=~finite;
    if any(bad(:))
        geoscatter(ax,latG(bad),lonG(bad),20,[0.48 0.48 0.48],'x', ...
            'LineWidth',0.8);
    end
    geoplot(ax,osm.Shape,'FaceColor','none','EdgeColor',[0.20 0.23 0.26], ...
        'LineWidth',0.45);
    [txLat,txLon]=projinv(cfg.crs,txX+cfg.projectedOriginX_m, ...
        txY+cfg.projectedOriginY_m);
    geoscatter(ax,txLat,txLon,145,[0.90 0.12 0.08],'p','filled', ...
        'MarkerEdgeColor','k','LineWidth',0.9);
    xBound=[xv(1) xv(end) xv(end) xv(1) xv(1)];
    yBound=[yv(1) yv(1) yv(end) yv(end) yv(1)];
    [latBound,lonBound]=projinv(cfg.crs, ...
        xBound+cfg.projectedOriginX_m,yBound+cfg.projectedOriginY_m);
    geoplot(ax,latBound,lonBound,'r-','LineWidth',3);
    geolimits(ax,[min(latG(:)) max(latG(:))],[min(lonG(:)) max(lonG(:))]);
    geobasemap(ax,'satellite');
    title(ax,sprintf('Outdoor RSS | %.0f MHz',cfg.frequenciesHz(fi)/1e6));
    ax.CLim=limitsRSS;
    validX=Xg(finite); validY=Yg(finite);
    hull=convhull(validX,validY);
    inside=inpolygon(Xq,Yq,validX(hull),validY(hull));
    thisSamples=sampleTable(sampleTable.Frequency_Hz==cfg.frequenciesHz(fi),:);
    statusRaster=reshape(thisSamples.RayStatus,size(Xg));
    nearestStatus=statusRaster(sub2ind(size(statusRaster),iy,ix));
    method=repmat("Natural-neighbor interpolation",numel(Xq),1);
    method(~inside(:))="Nearest-neighbor extrapolation";
    method(inside(:) & nearestStatus(:)~="Computed")= ...
        "Interpolated; nearest ray-grid sample had no path";
    interpolatedTables{fi}=table(repmat(cfg.frequenciesHz(fi),numel(Xq),1), ...
        Xq(:),Yq(:),latQ(:),lonQ(:),Zq(:),nearestStatus(:),method, ...
        'VariableNames',{'Frequency_Hz','X_local_m','Y_local_m','Latitude', ...
        'Longitude','RSS_interpolated_dBm','NearestSampleRayStatus','Method'});
end
colormap(fig,turbo(256));
cb=colorbar; cb.Layout.Tile='east'; cb.Label.String='RSS (dBm)';
sgtitle(fig,{"Kookmin campus outdoor LoRa RSS field", ...
    sprintf("Ray trace 50 m grid + natural-neighbor interpolation/nearest extrapolation; gray x = no ray; outdoor Rx %.1f m AGL", ...
    spacing,cfg.rxHeightAGL_m)},'FontWeight','bold');
exportgraphics(fig,fullfile(outDir,"rss_propagation_heatmaps.png"),Resolution=300);
close(fig);
writetable(vertcat(interpolatedTables{:}), ...
    fullfile(outDir,"propagation_heatmap_interpolated.csv"));
end

function makeNodeRSSCoverageMaps(T,nodes,cfg,txX,txY,osm,outDir)
% Interpolate existing per-building receiver RSS samples onto satellite maps.
% No additional propagation calculation is performed in this visualization.
validAll=T(isfinite(T.RSS_dBm),:);
assert(~isempty(validAll),'No computed RSS samples are available for interpolation.');
limitsRSS=[floor(min(validAll.RSS_dBm)),ceil(max(validAll.RSS_dBm))];
nodeTypes=["rooftop","indoor_virtual"];
typeLabels=["Rooftop Rx","Virtual indoor Rx"];
frequency=unique(T.Frequency_Hz,'stable');
assert(numel(frequency)==2,'Expected two frequency bands for the comparison.');
allInterpolated=cell(numel(nodeTypes)*numel(frequency),1);
fig=figure(Name="Node RSS interpolated coverage maps",Color="w",Position=[50 50 1920 1080]);
tlo=tiledlayout(fig,2,2,'TileSpacing','compact','Padding','compact');
writeIndex=0;
for ti=1:numel(nodeTypes)
    n=nodes(nodes.NodeType==nodeTypes(ti),:);
    for fi=1:numel(frequency)
        r=T(T.NodeType==nodeTypes(ti) & T.Frequency_Hz==frequency(fi),:);
        [tf,loc]=ismember(n.NodeID,r.NodeID);
        rss=NaN(height(n),1); rss(tf)=r.RSS_dBm(loc(tf));
        good=tf & isfinite(rss);
        bad=tf & ~isfinite(rss);
        assert(nnz(good)>=3,'At least three valid building samples are needed for 2D interpolation.');
        sx=n.X_local_m(good); sy=n.Y_local_m(good); sv=rss(good);
        % Query raster is only a display interpolation of the measured/modelled Rx samples.
        xv=linspace(min(sx)-45,max(sx)+45,190);
        yv=linspace(min(sy)-45,max(sy)+45,150);
        [Xq,Yq]=meshgrid(xv,yv);
        F=scatteredInterpolant(sx,sy,sv,'natural','nearest');
        Zq=F(Xq,Yq);
        k=convhull(sx,sy);
        inside=inpolygon(Xq,Yq,sx(k),sy(k));
        method=repmat("nearest_extrapolation",numel(Xq),1);
        method(inside(:))="natural_interpolation";
        [latq,lonq]=projinv(cfg.crs,Xq+cfg.projectedOriginX_m,Yq+cfg.projectedOriginY_m);
        writeIndex=writeIndex+1;
        allInterpolated{writeIndex}=table(repmat(frequency(fi),numel(Xq),1), ...
            repmat(nodeTypes(ti),numel(Xq),1),Xq(:),Yq(:),latq(:),lonq(:),Zq(:),method, ...
            repmat(nnz(good),numel(Xq),1),'VariableNames', ...
            {'Frequency_Hz','NodeType','X_local_m','Y_local_m','Latitude','Longitude', ...
            'RSS_interpolated_dBm','InterpolationMethod','RSSSampleCount'});

        ax=geoaxes(tlo); ax.Layout.Tile=(ti-1)*2+fi; hold(ax,'on');
        geobasemap(ax,'satellite');
        % Dense translucent points render the interpolated raster over the basemap.
        geoscatter(ax,latq(:),lonq(:),34,Zq(:),'filled', ...
            'MarkerFaceAlpha',0.58,'MarkerEdgeAlpha',0.0);
        try
            geoplot(ax,osm.Shape,'Color',[0.08 0.9 0.85],'LineWidth',0.55, ...
                'HandleVisibility','off');
        catch
            % Satellite imagery remains usable if this MATLAB release cannot draw the geotable outlines.
        end
        % Model domain outline, Tx, computed node samples, and failed-link samples.
        latB=[latq(1,1) latq(1,end) latq(end,end) latq(end,1) latq(1,1)];
        lonB=[lonq(1,1) lonq(1,end) lonq(end,end) lonq(end,1) lonq(1,1)];
        geoplot(ax,latB,lonB,'r-','LineWidth',1.7,'DisplayName','Interpolation domain');
        [txLat,txLon]=projinv(cfg.crs,txX+cfg.projectedOriginX_m,txY+cfg.projectedOriginY_m);
        geoplot(ax,txLat,txLon,'p','MarkerSize',13,'MarkerFaceColor',[1 0.1 0.08], ...
            'MarkerEdgeColor','w','DisplayName','Tx');
        if any(good)
            if nodeTypes(ti)=="rooftop", marker='o'; else, marker='s'; end
            geoscatter(ax,n.Latitude(good),n.Longitude(good),85,rss(good),marker, ...
                'filled','MarkerEdgeColor','k','LineWidth',1.0,'DisplayName','RSS sample nodes');
        end
        if any(bad)
            geoscatter(ax,n.Latitude(bad),n.Longitude(bad),70,[0.35 0.35 0.35],'x', ...
                'LineWidth',2,'DisplayName','No ray result');
            for bi=find(bad(:))'
                text(ax,n.Latitude(bi),n.Longitude(bi),n.BuildingName(bi), ...
                    'Color','w','FontSize',8,'FontWeight','bold','Interpreter','none');
            end
        end
        title(ax,sprintf('%s | %.0f MHz | %d/%d RSS samples', ...
            typeLabels(ti),frequency(fi)/1e6,nnz(good),height(n)),'Interpreter','none');
        ax.LatitudeLabel.String=''; ax.LongitudeLabel.String='';
        clim(ax,limitsRSS); colormap(ax,turbo(256));
    end
end
cb=colorbar; cb.Layout.Tile='east'; cb.Label.String='RSS (dBm)'; cb.Limits=limitsRSS;
sgtitle(tlo,['Kookmin campus RSS interpolated from receiver nodes | common color scale ' ...
    '(natural inside sample hull; nearest extrapolation outside)'], ...
    'FontWeight','bold');
exportgraphics(fig,fullfile(outDir,'rss_node_interpolated_coverage.png'),Resolution=300);
close(fig);
% A second, wide two-frequency view mirrors the spatial propagation-map
% layout. It uses the same rooftop node-derived surfaces, not new ray traces.
wide=figure(Name="Interpolated rooftop RSS propagation map",Color="w", ...
    Position=[50 100 1920 760]);
tlw=tiledlayout(wide,1,2,'TileSpacing','compact','Padding','compact');
for fi=1:numel(frequency)
    ax=geoaxes(tlw); ax.Layout.Tile=fi; hold(ax,'on'); geobasemap(ax,'satellite');
    q=allInterpolated{fi};
    geoscatter(ax,q.Latitude,q.Longitude,42,q.RSS_interpolated_dBm,'filled', ...
        'MarkerFaceAlpha',0.60,'MarkerEdgeAlpha',0.0);
    try
        geoplot(ax,osm.Shape,'Color',[0.08 0.9 0.85],'LineWidth',0.55, ...
            'HandleVisibility','off');
    catch
    end
    roof=nodes(nodes.NodeType=="rooftop",:);
    rr=T(T.NodeType=="rooftop" & T.Frequency_Hz==frequency(fi),:);
    [tf,loc]=ismember(roof.NodeID,rr.NodeID); vals=NaN(height(roof),1);
    vals(tf)=rr.RSS_dBm(loc(tf)); ok=tf & isfinite(vals); miss=tf & ~isfinite(vals);
    geoscatter(ax,roof.Latitude(ok),roof.Longitude(ok),95,vals(ok),'o','filled', ...
        'MarkerEdgeColor','k','LineWidth',1.0,'DisplayName','RSS sample Rx');
    if any(miss)
        geoscatter(ax,roof.Latitude(miss),roof.Longitude(miss),75,[0.35 0.35 0.35], ...
            'x','LineWidth',2,'DisplayName','No ray result');
    end
    [txLat,txLon]=projinv(cfg.crs,txX+cfg.projectedOriginX_m,txY+cfg.projectedOriginY_m);
    geoplot(ax,txLat,txLon,'p','MarkerSize',14,'MarkerFaceColor',[1 0.1 0.08], ...
        'MarkerEdgeColor','w','DisplayName','Tx');
    title(ax,sprintf('Rooftop Rx RSS | %.0f MHz',frequency(fi)/1e6));
    clim(ax,limitsRSS); colormap(ax,turbo(256));
end
cbw=colorbar; cbw.Layout.Tile='east'; cbw.Label.String='RSS (dBm)'; cbw.Limits=limitsRSS;
sgtitle(tlw,'Interpolated radio field from rooftop receiver samples | natural within hull, nearest beyond', ...
    'FontWeight','bold');
exportgraphics(wide,fullfile(outDir,'rss_node_propagation_263_922.png'),Resolution=300);
close(wide);
writetable(vertcat(allInterpolated{:}),fullfile(outDir,'rss_node_interpolation_values.csv'));
end

function B=makeBuildingRSSValues(T,nodes,cfg,outDir)
% Direct ray RSS is retained. No-ray links use a clearly marked local IDW estimate.
freqs=unique(T.Frequency_Hz,'stable'); nout=height(nodes)*numel(freqs);
NodeID=strings(nout,1); BuildingName=NodeID; NodeType=NodeID;
Frequency_Hz=NaN(nout,1); RSS_dBm=NaN(nout,1); RSS_Method=NodeID;
EstimateNeighbors=NodeID; RaytraceStatus=NodeID; row=0;
for ni=1:height(nodes)
    for fi=1:numel(freqs)
        ri=find(T.NodeID==nodes.NodeID(ni) & T.Frequency_Hz==freqs(fi),1);
        if isempty(ri), continue; end
        r=T(ri,:); val=r.RSS_dBm; method="Ray tracing"; neighbors="";
        if ~isfinite(val)
            cand=T(T.NodeType==nodes.NodeType(ni) & T.Frequency_Hz==freqs(fi) & ...
                isfinite(T.RSS_dBm),:);
            [tf,loc]=ismember(cand.NodeID,nodes.NodeID);
            cand=cand(tf,:); loc=loc(tf);
            d=hypot(nodes.X_local_m(loc)-nodes.X_local_m(ni), ...
                nodes.Y_local_m(loc)-nodes.Y_local_m(ni));
            [d,ord]=sort(d); cand=cand(ord,:); nUse=min(3,height(cand));
            if nUse>0
                cand=cand(1:nUse,:); d=d(1:nUse); w=1./max(d,1).^2;
                val=sum(w.*cand.RSS_dBm)/sum(w);
                neighbors=join(cand.BuildingName,"; "); method="Neighbor IDW-3";
            else
                method="Unavailable: no nearby valid RSS";
            end
        end
        row=row+1; NodeID(row)=r.NodeID; BuildingName(row)=r.BuildingName;
        NodeType(row)=r.NodeType; Frequency_Hz(row)=freqs(fi); RSS_dBm(row)=val;
        RSS_Method(row)=method; EstimateNeighbors(row)=neighbors; RaytraceStatus(row)=r.LinkStatus;
    end
end
B=table(NodeID(1:row),BuildingName(1:row),NodeType(1:row),Frequency_Hz(1:row), ...
    RSS_dBm(1:row),RSS_Method(1:row),EstimateNeighbors(1:row),RaytraceStatus(1:row), ...
    'VariableNames',{'NodeID','BuildingName','NodeType','Frequency_Hz','RSS_dBm', ...
    'RSS_Method','EstimateNeighbors','RaytraceStatus'});
writetable(B,fullfile(outDir,'building_rss_values.csv'));
summary=table(strings(height(nodes),1),strings(height(nodes),1),strings(height(nodes),1), ...
    NaN(height(nodes),1),NaN(height(nodes),1),NaN(height(nodes),1), ...
    strings(height(nodes),1),strings(height(nodes),1),strings(height(nodes),1), ...
    strings(height(nodes),1),'VariableNames',{'NodeID','BuildingName','NodeType', ...
    'RSS_263MHz_dBm','RSS_922MHz_dBm','Difference_922_minus_263_dB', ...
    'Method_263MHz','Method_922MHz','Neighbors_263MHz','Neighbors_922MHz'});
for ni=1:height(nodes)
    a=B(B.NodeID==nodes.NodeID(ni) & B.Frequency_Hz==263e6,:);
    b=B(B.NodeID==nodes.NodeID(ni) & B.Frequency_Hz==922e6,:);
    summary.NodeID(ni)=nodes.NodeID(ni); summary.BuildingName(ni)=nodes.BuildingName(ni);
    summary.NodeType(ni)=nodes.NodeType(ni); summary.RSS_263MHz_dBm(ni)=a.RSS_dBm;
    summary.RSS_922MHz_dBm(ni)=b.RSS_dBm;
    summary.Difference_922_minus_263_dB(ni)=b.RSS_dBm-a.RSS_dBm;
    summary.Method_263MHz(ni)=a.RSS_Method; summary.Method_922MHz(ni)=b.RSS_Method;
    summary.Neighbors_263MHz(ni)=a.EstimateNeighbors; summary.Neighbors_922MHz(ni)=b.EstimateNeighbors;
end
writetable(summary,fullfile(outDir,'building_rss_comparison.csv'));
end

function makeRSSNodeMapWithEstimates(T,nodes,cfg,txX,txY,osm,outDir)
% The primary node-map filename now shows RSS as whole-building footprint fills.
makeBuildingRSSMaps(T,nodes,cfg,txX,txY,osm,outDir);
copyfile(fullfile(outDir,'rss_building_rss_maps.png'), ...
    fullfile(outDir,'rss_node_maps.png'),'f');
end

function makeBuildingRSSMaps(B,nodes,cfg,txX,txY,osm,outDir)
% Fill each actual footprint using the building-level RSS table.
valid=B(isfinite(B.RSS_dBm),:); lim=[floor(min(valid.RSS_dBm)),ceil(max(valid.RSS_dBm))];
freqs=unique(B.Frequency_Hz,'stable'); kinds=["rooftop","indoor_virtual"];
labels=["Rooftop","Indoor virtual"];
fig=figure(Name='Building RSS maps',Color='w',Position=[60 60 1920 1080]);
tl=tiledlayout(fig,2,2,'TileSpacing','compact','Padding','compact'); cmap=turbo(256);
for ki=1:2
    sub=nodes(nodes.NodeType==kinds(ki),:);
    for fi=1:numel(freqs)
        ax=geoaxes(tl); ax.Layout.Tile=(ki-1)*2+fi; hold(ax,'on');
        try, ax.Toolbar.Visible='off'; catch, end
        for ni=1:height(sub)
            b=B(B.NodeID==sub.NodeID(ni)&B.Frequency_Hz==freqs(fi),:);
            oi=find(string(osm.ID)==sub.OSM_ID(ni),1);
            if isempty(oi)||isempty(b)||~isfinite(b.RSS_dBm), continue; end
            ci=max(1,min(256,round(1+255*(b.RSS_dBm-lim(1))/max(eps,lim(2)-lim(1)))));
            ls='-'; lw=0.9;
            geoplot(ax,osm.Shape(oi),'FaceColor',cmap(ci,:),'FaceAlpha',0.62, ...
                'EdgeColor',[0.12 0.12 0.12],'LineStyle',ls,'LineWidth',lw);
            nm=sub.BuildingName(ni);
            text(ax,sub.Latitude(ni),sub.Longitude(ni),nm,'FontSize',8, ...
                'Color','k','FontWeight','bold','Interpreter','none');
        end
        [txLat,txLon]=projinv(cfg.crs,txX+cfg.projectedOriginX_m,txY+cfg.projectedOriginY_m);
        geoplot(ax,txLat,txLon,'p','MarkerSize',11,'MarkerFaceColor','r','MarkerEdgeColor','w');
        try, geobasemap(ax,'streets-light'); catch, geobasemap(ax,'none'); end
        ax.Grid='off'; ax.LatitudeLabel.String=''; ax.LongitudeLabel.String='';
        title(ax,sprintf('%s | %.0f MHz',labels(ki),freqs(fi)/1e6));
        geolimits(ax,[min([sub.Latitude;txLat])-0.0006 max([sub.Latitude;txLat])+0.0006], ...
            [min([sub.Longitude;txLon])-0.0008 max([sub.Longitude;txLon])+0.0008]);
        clim(ax,lim); colormap(ax,cmap);
    end
end
cb=colorbar; cb.Layout.Tile='east'; cb.Label.String='RSS (dBm)'; cb.Limits=lim;
sgtitle(tl,'Building footprints filled by RSS | estimated links use nearby-building values', ...
    'FontWeight','bold');
exportgraphics(fig,fullfile(outDir,'rss_building_rss_maps.png'),Resolution=300); close(fig);
end
