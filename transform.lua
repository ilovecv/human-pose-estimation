local py = require 'fb.python'

function getTransform(center, scale, res)
    local h = 200 * scale
    local t = torch.eye(3)

    -- Scale
    t[1][1] = res / h
    t[2][2] = res / h

    -- Translate
    t[1][3] = res * (-center[1] / h + .5)
    t[2][3] = res * (-center[2] / h + .5)

    return t
end

-- Transform the coordinates between to the image space
function transform(pt, center, scale, res, invert)
    local pt_new = torch.ones(3)
    pt_new[1], pt_new[2] = pt[1], pt[2]
    local t = getTransform(center, scale, res)
    if invert then
        t = torch.inverse(t)
    end
    local new_point = (t*pt_new):sub(1,2):int()
    return new_point
end

-- Crop based on the image center & scale
function crop(img, center, scale, res)
    local l1 = transform({1,1}, center, scale, res, true)
    local l2 = transform({res,res}, center, scale, res, true)

    local pad = math.floor(torch.norm((l1 - l2):float())/2 - (l2[1]-l1[1])/2)
    
    if img:size():size() < 3 then
      img = torch.repeatTensor(img,3,1,1)
    end

    local newDim = torch.IntTensor({img:size()[1], l2[2] - l1[2], l2[1] - l1[1]})
    local newImg = torch.zeros(newDim[1],newDim[2],newDim[3])
    local height, width = img:size()[2], img:size()[3]

    local newX = torch.Tensor({math.max(1, -l1[1]+1), math.min(l2[1], width) - l1[1]})
    local newY = torch.Tensor({math.max(1, -l1[2]+1), math.min(l2[2], height) - l1[2]})
    local oldX = torch.Tensor({math.max(1, l1[1]+1), math.min(l2[1], width)})
    local oldY = torch.Tensor({math.max(1, l1[2]+1), math.min(l2[2], height)})

    newImg:sub(1,newDim[1],newY[1],newY[2],newX[1],newX[2]):copy(img:sub(1,newDim[1],oldY[1],oldY[2],oldX[1],oldX[2]))

    newImg = image.scale(newImg,res,res)
    return newImg
end

function getPreds(heatmaps, center, scale)
    if heatmaps:size():size() == 3 then heatmaps = heatmaps:view(1, unpack(heatmaps:size():totable())) end

    -- Get locations of maximum activations
    local max, idx = torch.max(heatmaps:view(heatmaps:size(1), heatmaps:size(2), heatmaps:size(3) * heatmaps:size(4)), 3)
    local preds = torch.repeatTensor(idx, 1, 1, 2):float()
    preds[{{}, {}, 1}]:apply(function(x) return (x - 1) % heatmaps:size(4) + 1 end)
    preds[{{}, {}, 2}]:add(-1):div(heatmaps:size(3)):floor():add(.5)

    -- Get the coordinates in the original space
    local preds_orig = torch.zeros(preds:size())
    for i = 1,heatmaps:size(1) do        -- Number of samples
        for j = 1,heatmaps:size(2) do    -- Number of output heatmaps for one sample
            preds_orig[i][j] = transform(preds[i][j],center,scale,heatmaps:size(3),true)
        end
    end

    return preds, preds_orig
end

function evaluate(predictions,groundTruth)
  local n = predictions:size()[1]
  gnds = torch.Tensor(n,16,2)
  for i=1,n do
    gnds[{{i},{},{}}] = groundTruth[i].points
  end

  local dists = torch.Tensor(predictions:size(2),predictions:size(1))
  -- Calculate L2
	for i = 1,predictions:size(1) do
		for j = 1,predictions:size(2) do
			if gnds[i][j][1] > 1 and gnds[i][j][2] > 1 then
				dists[j][i] = torch.dist(gnds[i][j],predictions[i][j])/groundTruth[i].headSize
			else
				dists[j][i] = -1
			end
		end
	end

  return dists
end

function calculateMetrics(dists,opts)
  local pdists = dists:clone()
  local threshold =  (function() if opts.dataset =='mpii' then return 0.5 else return 0.2 end end)() 
	dists:apply(function(x)
		if x>=0 and x<=threshold then
			return 1
		elseif x>threshold then
			return 0
		end
	end)
	local count = torch.zeros(16)
	local sums = torch.zeros(16)
	for i=1,16 do
		dists[i]:apply(function(x)
			if x ~= -1 then
				count[i] = count[i] + 1
				sums[i] = sums[i] + x
			end
		end)
	end
  
	local partNames = {'Head', 'Knee', 'Ankle', 'Shoulder', 'Elbow', 'Wrist', 'Hip'}
	local partsC = torch.Tensor({{9,10},{2,5},{1,6},{13,14},{12,15},{11,16},{3,4}})
	print('PCKh results:')
	for i=1,#partNames do
		print(partNames[i]..': ',(sums[partsC[i][1]]/count[partsC[i][1]]+sums[partsC[i][2]]/count[partsC[i][1]])*100/2)
	end
  
  py.exec([=[
import numpy as np
import matplotlib.pyplot as plt
partsC = partsC - 1
pairs = np.array([[1,2], [2,3], [3,7], [4,5], [4,7], [5,6], [7,9], [9,10], [14,9], [11,12], [12,13], [13,9], [14,15], [15,16]])-1
var = np.arange(0,threshold+.01,0.01)
print dists.shape
    
f, axarr = plt.subplots(3, 2, sharex='col', sharey='row')

index = 0

for el in axarr.ravel():
  el.axis([0, threshold, 0, 1])
  el.set_title(partNames[index])
  cum_err = np.zeros(var.shape[0])
  for j in range(var.shape[0]):
    cum_err[j] = (dists[[partsC[index,0],partsC[index,1]],...]<var[j]).sum().astype('float')/(count[partsC[index,0]]+count[partsC[index,1]])
  el.plot(var,cum_err)
  index = index + 1
plt.show()
]=],{partNames = partNames, partsC = partsC, dists = pdists, count=count, threshold = threshold})
end

-- Helper function for applying an operation whether passed a table or tensor
function applyFn(fn, t, t2)
    local t_ = {}
    if type(t) == "table" then
        if t2 then
            for i = 1,#t do t_[i] = applyFn(fn, t[i], t2[i]) end
        else
            for i = 1,#t do t_[i] = applyFn(fn, t[i]) end
        end
    else t_ = fn(t, t2) end
    return t_
end

function shuffleLR(x)
    local dim
    if x:nDimension() == 4 then
        dim = 2
    else
        assert(x:nDimension() == 3)
        dim = 1
    end

    local matched_parts = {
        {1,6},   {2,5},   {3,4},
        {11,16}, {12,15}, {13,14}
    }

    for i = 1,#matched_parts do
        local idx1, idx2 = unpack(matched_parts[i])
        local tmp = x:narrow(dim, idx1, 1):clone()
        x:narrow(dim, idx1, 1):copy(x:narrow(dim, idx2, 1))
        x:narrow(dim, idx2, 1):copy(tmp)
    end

    return x
end

function flip(x)
    local y = torch.FloatTensor(x:size())
    for i = 1, x:size(1) do
        image.hflip(y[i], x[i]:float())
    end
    return y:typeAs(x)
end