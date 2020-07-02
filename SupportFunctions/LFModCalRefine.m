% todo[doc]
% LFCalRefine - refine calibration by minimizing point/ray reprojection error, called by LFUtilCalLensletCam
%
% Usage:
%     CalOptions = LFCalRefine( FileOptions, CalOptions )
%
% This function is called by LFUtilCalLensletCam to refine an initial camera model and pose
% estimates through optimization. This follows the calibration procedure described in:
%
% D. G. Dansereau, O. Pizarro, and S. B. Williams, "Decoding, calibration and rectification for
% lenslet-based plenoptic cameras," in Computer Vision and Pattern Recognition (CVPR), IEEE
% Conference on. IEEE, Jun 2013.
%
% Minor differences from the paper: camera parameters are automatically initialized, so no prior
% knowledge of the camera's parameters are required; the free intrinsics parameters have been
% reduced by two: H(3:4,5) were previously redundant with the camera's extrinsics, and are now
% automatically centered; and the light field indices [i,j,k,l] are 1-based in this implementation,
% and not 0-based as described in the paper.
%
% Inputs:
%
%   FileOptions : struct with file options
%   .WorkingPath : Path to folder containing decoded checkerboard images. Checkerboard corners must
%                 be identified prior to calling this function, by running LFCalFindCheckerCorners
%                 for example. An initial estiamte must be provided in a CalInfo file, as generated
%                 by LFCalInit. LFUtilCalLensletCam demonstrates the complete procedure.
%
%     CalOptions struct controls calibration parameters :
%                   .Iteration : todo[doc] default 1:'NoDistort' excludes distortion parameters from the optimization
%                                 process; for any other value, distortion parameters are included
%               .AllFeatsFname : Name of the file containing the summarized checkerboard
%                                 information, as generated by LFCalFindCheckerCorners. Note that
%                                 this parameter is automatically set in the CalOptions struct
%                                 returned by LFCalFindCheckerCorners.
%                 .CalInfoFname : Name of the file containing an initial estimate, to be refined.
%                                 Note that this parameter is automatically set in the CalOptions
%                                 struct returned by LFCalInit.
%          .ExpectedCheckerSize : Number of checkerboard corners, as recognized by the automatic
%                                 corner detector; edge corners are not recognized, so a standard
%                                 8x8-square chess board yields 7x7 corners
%            .LensletBorderSize : Number of pixels to skip around the edges of lenslets, a low
%                                 value of 1 or 0 is generally appropriate
%                   .SaveResult : Set to false to perform a "dry run"
%        [optional]    .OptTolX : Determines when the optimization process terminates. When the
%                                 estimted parameter values change by less than this amount, the
%                                 optimization terminates. See the Matlab documentation on lsqnonlin,
%                                 option `TolX' for more information. The default value of 5e-5 is set
%                                 within the LFCalRefine function; a value of 0 means the optimization
%                                 never terminates based on this criterion.
%      [optional]    .OptTolFun : Similar to OptTolX, except this tolerance deals with the error value.
%                                 This corresponds to Matlab's lsqnonlin option `TolFun'. The default
%                                 value of 0 is set within the LFCalRefine function, and means the
%                                 optimization never terminates based on this criterion.
%
% Outputs :
%
%     CalOptions struct maintains the fields of the input CalOptions, and adds the fields:
%
%                    .LFSize : Size of the light field, in samples
%            .IJVecToOptOver : Which samples in i and j were included in the optimization
%           .IntrinsicsToOpt : Which intrinsics were optimized, these are indices into the 5x5
%                              lenslet camera intrinsic matrix
%     .DistortionParamsToOpt : Which distortion params were optimized
%     .PreviousCamIntrinsics : Previous estimate of the camera's intrinsics
%     .PreviousCamDistortion : Previous estimate of the camera's distortion parameters
%                    .NPoses : Number of poses in the dataset
%
%
% User guide: <a href="matlab:which LFToolbox.pdf; open('LFToolbox.pdf')">LFToolbox.pdf</a>
% See also:  LFUtilCalLensletCam, LFCalFindCheckerCorners, LFCalInit, LFUtilDecodeLytroFolder

% Copyright (c) 2013-2020 Donald G. Dansereau

function CalOptions = LFModCalRefine( FileOptions, CalOptions )

%---Defaults---
CalOptions = LFDefaultField( 'CalOptions', 'OptTolX', 5e-5 );
CalOptions = LFDefaultField( 'CalOptions', 'OptTolFun', 0 );

CalOptions = LFDefaultField( 'CalOptions', 'Fn_PerObsError', 'ObsError_PtRay' );
CalOptions = LFDefaultField( 'CalOptions', 'Fn_OptParamsInit', 'OptParamsInit' );
CalOptions = LFDefaultField( 'CalOptions', 'Fn_ModelToOptParams', 'ModelToOptParams' );
CalOptions = LFDefaultField( 'CalOptions', 'Fn_OptParamsToModel', 'OptParamsToModel' );
CalOptions = LFDefaultField( 'CalOptions', 'Fn_ObsToRay', 'LFObsToRay_FreeIntrinH' );

%---Load feaature observations and previous cal state---
AllFeatsFname = fullfile(FileOptions.WorkingPath, CalOptions.AllFeatsFname);
CalInfoFname = fullfile(FileOptions.WorkingPath, CalOptions.CalInfoFname);

load(AllFeatsFname, 'AllFeatObs', 'LFSize');
[EstCamPosesV, CameraModel, LFMetadata, CamInfo] = ...
	LFStruct2Var( LFReadMetadata(CalInfoFname), 'EstCamPosesV', 'CameraModel', 'LFMetadata', 'CamInfo' );
CalOptions.LFSize = LFSize;

%---Set up optimization variables---
fprintf('\n===Calibration refinement step===\n');

CalOptions.IJVecToOptOver = CalOptions.LensletBorderSize+1:LFSize(1)-CalOptions.LensletBorderSize;
fprintf('    IJ Range: ');
disp(CalOptions.IJVecToOptOver);

[CalOptions, CameraModel] = feval( CalOptions.Fn_OptParamsInit, CameraModel, CalOptions );

CalTarget = CalOptions.CalTarget;
CalTarget = [CalTarget; ones(1,size(CalTarget,2))]; % homogeneous coord

%---Compute initial error between projected and measured feature positions---
%---Encode params and grab info required to build Jacobian sparsity matrix---
CalOptions.NPoses = size(EstCamPosesV,1);
[OptParams0, ParamsInfo, JacobSensitivity] = ...
	feval( CalOptions.Fn_ModelToOptParams, EstCamPosesV, CameraModel, CalOptions );

[ModelError0, JacobPattern] = FindError2DFeats( OptParams0, AllFeatObs, CalTarget, CalOptions, ParamsInfo, JacobSensitivity );
if( numel(ModelError0) == 0 )
	error('No valid grid points found -- possible grid parameter mismatch');
end

fprintf('\n    Start SSE: %g m^2, RMSE: %g m\n', sum((ModelError0).^2), sqrt(mean((ModelError0).^2)));

%---Start the optimization---
ObjectiveFunc = @(Params) FindError2DFeats(Params, AllFeatObs, CalTarget, CalOptions, ParamsInfo, JacobSensitivity );
OptimOptions = optimset('Display','iter', ...
	'TolX', CalOptions.OptTolX, ...
	'TolFun',CalOptions.OptTolFun, ...
	'JacobPattern', JacobPattern);

Bounds = reshape( ParamsInfo.Bounds, 2, [] );
[OptParams, ~, FinalDist] = lsqnonlin(ObjectiveFunc, OptParams0, Bounds(1,:), Bounds(2,:), OptimOptions);

%---Decode the resulting parameters and check the final error---
[EstCamPosesV, CameraModel] = ...
	feval( CalOptions.Fn_OptParamsToModel, OptParams, CalOptions, ParamsInfo );
fprintf(' ---Finished calibration refinement---\n');

ReprojectionError = struct( 'SSE', sum(FinalDist.^2), 'RMSE', sqrt(mean(FinalDist.^2)) );
fprintf('\n    Start SSE: %g m^2, RMSE: %g m\n    Finish SSE: %g m^2, RMSE: %g m\n', ...
	sum((ModelError0).^2), sqrt(mean((ModelError0).^2)), ...
	ReprojectionError.SSE, ReprojectionError.RMSE );

TimeStamp = datestr(now,'ddmmmyyyy_HHMMSS');
GeneratedByInfo = struct('mfilename', mfilename, 'time', TimeStamp, 'VersionStr', LFToolboxVersion);

SaveFname = fullfile(FileOptions.WorkingPath, CalOptions.CalInfoFname);
fprintf('\nSaving to %s\n', SaveFname);

LFWriteMetadata(SaveFname, LFVar2Struct(GeneratedByInfo, CameraModel, EstCamPosesV, CalOptions, ReprojectionError, LFMetadata, CamInfo));

end

%---------------------------------------------------------------------------------------------------
function [ModelError, JacobPattern] = FindError2DFeats( OptParams, AllFeatObs, CalTarget, CalOptions, ParamsInfo, JacobSensitivity )
%---Decode optim params---
[EstCamPosesV, CameraModel] = ...
	feval( CalOptions.Fn_OptParamsToModel, OptParams, CalOptions, ParamsInfo );

%---Tally up the total number of observations---
TotFeatObs = size( [AllFeatObs{:,CalOptions.IJVecToOptOver,CalOptions.IJVecToOptOver}], 2 );
CheckFeatObs = 0;

%---Preallocate JacobPattern if it's requested---
if( nargout >= 2 )
	JacobPattern = zeros(TotFeatObs, length( OptParams ));
end

%---Preallocate distances---
ModelError = zeros(1, TotFeatObs);

%---Compute point-plane distances---
OutputIdx = 0;
for( PoseIdx = 1:CalOptions.NPoses )
	%---Convert the pertinent camera pose to a homogeneous transform---
	CurEstCamPoseV = squeeze(EstCamPosesV(PoseIdx, :));
	CurEstCamPoseH = eye(4);
	CurEstCamPoseH(1:3,1:3) = rodrigues(CurEstCamPoseV(4:6));
	CurEstCamPoseH(1:3,4) = CurEstCamPoseV(1:3);
	
	%---Transform ideal 3D feature coords into camera's reference frame---
	CalTarget_CamFrame = CurEstCamPoseH * CalTarget; % todo[refactor]: is CurEstCamPoseH actually the inverse of cam pose?
	CalTarget_CamFrame = CalTarget_CamFrame(1:3,:); % won't be needing homogeneous points
	
	%---Iterate through the feature observations---
	for( TIdx = CalOptions.IJVecToOptOver )
		for( SIdx = CalOptions.IJVecToOptOver )
			CurFeatObs = AllFeatObs{PoseIdx, TIdx,SIdx};
			NFeatObs = size(CurFeatObs,2);
			if( NFeatObs ~= prod(CalOptions.ExpectedCheckerSize) )
				continue; % this implementation skips incomplete observations
			end
			CheckFeatObs = CheckFeatObs + NFeatObs;
			
			%---Assemble observed feature positions into complete 4D [i,j,k,l] indices---
			CurFeatObs_Idx = [CurFeatObs; ones(1, NFeatObs)];
			
			%---Find error---
			CurDist3D = feval( CalOptions.Fn_PerObsError, CurFeatObs_Idx, CameraModel, CalTarget_CamFrame, CalOptions );
			ModelError(OutputIdx + (1:NFeatObs)) = CurDist3D;
			
			%---Optionally compute jacobian sensitivity matrix---
			if( nargout >=2 )
				% Build the Jacobian pattern. First we enumerate those observations related to
				% the current pose, then find all parameters to which those observations are
				% sensitive. This relies on the JacobSensitivity list constructed by the
				% FlattenStruct function.
				CurObservationList = OutputIdx + (1:NFeatObs);
				CurSensitivityList = (JacobSensitivity==PoseIdx | JacobSensitivity==0);
				JacobPattern(CurObservationList, CurSensitivityList) = 1;
			end
			OutputIdx = OutputIdx + NFeatObs;
		end
	end
end

%---Check that the expected number of observations have gone by---
if( CheckFeatObs ~= TotFeatObs )
	error(['Mismatch between expected (%d) and observed (%d) number of feature observations' ...
		' -- possibly caused by a grid parameter mismatch'], TotFeatObs, CheckFeatObs);
end
end

%---------------------------------------------------------------------------------------------------
%---Find error given features, camera model, and checkerboards---
% This method projects the features out as rays, and finds the ray-to-point distance
function CurDist = ObsError_PtRay( CurFeatObs, CameraModel, CalTarget_CamFrame, CalOptions )
NFeatObs = size(CurFeatObs,2);
CurFeatObs_Ray = ...
	feval( CalOptions.Fn_ObsToRay, CurFeatObs, CameraModel );

%---Find 3D point-ray distance---
STPlaneIntersect = [CurFeatObs_Ray(1:2,:); zeros(1,NFeatObs)];
% Here interpret u,v as relative, at a distance of 1 m
% Thus we use a relative 2pp, with D = 1m.
RayDir = [CurFeatObs_Ray(3:4,:); ones(1,NFeatObs)];
CurDist = LFFind3DPtRayDist( STPlaneIntersect, RayDir, CalTarget_CamFrame );
end

%---------------------------------------------------------------------------------------------------
function [CalOptions, CameraModel] = OptParamsInit( CameraModel, CalOptions )
CalOptions.IntrinsicsToOpt = sub2ind([5,5], [1,3, 2,4, 1,3, 2,4], [1,1, 2,2, 3,3, 4,4]);
switch( CalOptions.Iteration )
	case 1
		CalOptions.DistortionParamsToOpt = [];
	otherwise
		CalOptions.DistortionParamsToOpt = 1:5;
end

if( isempty(CameraModel.Distortion) && ~isempty(CalOptions.DistortionParamsToOpt) )
	CameraModel.Distortion( CalOptions.DistortionParamsToOpt ) = 0;
end
CalOptions.PreviousCameraModel = CameraModel;

fprintf('    Intrinsics: ');
disp(CalOptions.IntrinsicsToOpt);
if( ~isempty(CalOptions.DistortionParamsToOpt) )
	fprintf('    Distortion: ');
	disp(CalOptions.DistortionParamsToOpt);
end
end

%---------------------------------------------------------------------------------------------------
function [OptParams0, ParamsInfo, JacobSensitivity] = ModelToOptParams( EstCamPosesV, CameraModel, CalOptions )
% This makes use of FlattenStruct to reversibly flatten all params into a single array.
% It also applies the same process to a sensitivity list, to facilitate building a Jacobian
% Sparisty matrix.

% The 'P' structure contains all the parameters to encode, and the 'J' structure mirrors it exactly
% with a sensitivity list. Each entry in 'J' lists those poses that are senstitive to the
% corresponding parameter. e.g. The first estimated camera pose affects only observations made
% within the first pose, and so the sensitivity list for that parameter lists only the first pose. A
% `J' value of 0 means all poses are sensitive to that variable -- as in the case of the intrinsics,
% which affect all observations.
P.EstCamPosesV = EstCamPosesV;
J.EstCamPosesV = zeros(size(EstCamPosesV));
for( i=1:CalOptions.NPoses )
	J.EstCamPosesV(i,:) = i;
end
B.EstCamPosesV = [-inf;inf] .* ones(1,numel(P.EstCamPosesV));

P.IntrinParams = CameraModel.EstCamIntrinsicsH(CalOptions.IntrinsicsToOpt);
J.IntrinParams = zeros(size(CalOptions.IntrinsicsToOpt));
B.IntrinParams = [-inf;inf] .* ones(1,numel(P.IntrinParams));

P.DistortParams = CameraModel.Distortion(CalOptions.DistortionParamsToOpt);
J.DistortParams = zeros(size(CalOptions.DistortionParamsToOpt));
B.DistortParams = [-inf;inf] .* ones(1,numel(J.DistortParams));

[OptParams0, ParamsInfo] = FlattenStruct(P);
JacobSensitivity = FlattenStruct(J);
ParamsInfo.Bounds = FlattenStruct(B);
end

%---------------------------------------------------------------------------------------------------
function [EstCamPosesV, CameraModel] = OptParamsToModel( Params, CalOptions, ParamsInfo )
P = UnflattenStruct(Params, ParamsInfo);
EstCamPosesV = P.EstCamPosesV;

CameraModel = CalOptions.PreviousCameraModel;

CameraModel.EstCamIntrinsicsH(CalOptions.IntrinsicsToOpt) = P.IntrinParams;
CameraModel.Distortion(CalOptions.DistortionParamsToOpt) = P.DistortParams;

CameraModel.EstCamIntrinsicsH = LFRecenterIntrinsics(CameraModel.EstCamIntrinsicsH, CalOptions.LFSize);
end

