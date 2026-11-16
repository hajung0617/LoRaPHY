%% Kookmin campus DEM + OSM + building register (approximate 3D scene)
% MATLAB R2023b+ recommended for GLB. Requires Antenna Toolbox for Site Viewer.
% Put this script in the same folder as the .glb file.
rootDir = fileparts(mfilename('fullpath'));
glb = fullfile(rootDir, "kookmin_campus_terrain_buildings_v2.glb");
viewer = siteviewer(SceneModel=glb, ShowEdges=false, ShowOrigin=false);
% Cartesian local coordinates are in meters.
% Read building_height_matching_v2.csv for candidate building positions.
B = readtable(fullfile(rootDir,"building_height_matching_v2.csv"), VariableNamingRule="preserve");
disp(B(:,["osm_name","register_name","height_m","height_source","x_local_m","y_local_m","base_local_z_m"]));
% Example: assign positions AFTER selecting verified, outdoor, unobstructed locations.
% tx = txsite(CoordinateSystem="cartesian",AntennaPosition=[xTx;yTx;zTx], ...
%     TransmitterFrequency=263e6,TransmitterPower=1);
% rx = rxsite(CoordinateSystem="cartesian",AntennaPosition=[xRx;yRx;zRx]);
% pm = propagationModel("raytracing",Method="sbr",MaxNumReflections=2,MaxNumDiffractions=1);
% rays = raytrace(tx,rx,pm);
% NOTE: Material assignment for imported meshes and valid placement heights must be verified.
