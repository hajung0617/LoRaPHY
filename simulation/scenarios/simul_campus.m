
%% 국민대학교 3D 캠퍼스 지도 생성
clear; clc; close all;

% OSM 파일
projectRoot = fileparts(fileparts(mfilename("fullpath")));
osmFile = fullfile(projectRoot,"data","simulation","raw","map.osm");

% 파일 존재 여부 확인
assert(isfile(osmFile), "map.osm 파일을 찾을 수 없습니다.");

% 3D Site Viewer 생성
viewer = siteviewer( ...
    Buildings=osmFile, ...
    Terrain="gmted2010", ...
    Basemap="satellite", ...
    Name="Kookmin University LoRa Simulation");
