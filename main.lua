-- To create a new data file, this is what you need to do:
-- TODO add method to create upload submission
-- TODO display NLL instead of accuracy
require 'provider'
require 'xlua'
require 'optim'
require 'nn'
require 'provider'
c = require 'trepl.colorize'
torch.setdefaulttensortype('torch.FloatTensor')

-- Parse the command line arguments
--------------------------------------
opt = lapp[[
	--model 	(default linear_logsoftmax) 	model name
	-b,--batchSize 	(default 2) 			batch size
 	-r,--learningRate 	(default 1) 		learning rate
 	--learningRateDecay 	(default 1e-7) 		learning rate decay
	
	-s,--save 	(default "logs") 		subdirectory to save logs
	-S,--submission	(default no)			generate(overwrites) submission.csv file
 --weightDecay (default 0.0005) weightDecay
 -m,--momentum (default 0.9) momentum
 --epoch_step (default 25) epoch step
 --max_epoch (default 300) maximum number of iterations
 --backend (default nn) backend 
 --type (default float) cuda/float/cl
 -g,--gen_data (default no) whether to generate data file 
 -v,--validation (default 6) number of drivers to use in validation set
 -d,--datafile (default p.t7) file name of the data provider
]]



-- Generate data file if needed
-----------------------------------------------
height = 48
width = 64
provider = 0
if opt.gen_data ~= "no" then 
	-- TODO move most of this to provider.lua
	num_train = -1
	provider = Provider("/home/tc/data/distracted-drivers/", num_train, height, width, false)
	provider:normalize()

	-- Setup bettertraining/testing sets
	-- Bone-head way: take fist n drivers for training, use last v for validation
	print (c.blue"Creating datasets...")
	provider.labels = provider.labels+1

	provider.trainDriver= {}
	provider.validDriver= {}
	provider.trainData_n = 0
	provider.validData_n = 0

	train_idx = 1
	valid_idx = 1

	for i, id in ipairs(provider.driverId) do
		if id <= provider.drivers[20] then
			provider.trainData_n = provider.trainData_n + 1
		else
			provider.validData_n = provider.validData_n + 1
		end
	end
	
	provider.trainData = torch.Tensor(provider.trainData_n, 3, height, width)
	provider.validData = torch.Tensor(provider.validData_n, 3, height, width)

	provider.trainLabel = torch.Tensor(provider.trainData_n)
	provider.validLabel = torch.Tensor(provider.validData_n)
	
	provider.trainLabel:zero()
	provider.validLabel:zero()
	provider.trainData:zero()
	provider.validData:zero()

	for i, id in ipairs(provider.driverId) do
	    	xlua.progress(i, #provider.driverId)
		-- TODO: find a better way to make this split 
		if id <= provider.drivers[20] then
			-- training set
			provider.trainData[{{train_idx},{},{},{}}] = provider.data[i]
			provider.trainLabel[train_idx] = provider.labels[i]
			table.insert(provider.trainDriver, provider.driverId[i])
			train_idx = train_idx + 1
		else
			-- validation set
			provider.validData[{{valid_idx},{},{},{}}] = provider.data[i]
			provider.validLabel[valid_idx] = provider.labels[i]
			table.insert(provider.validDriver, provider.driverId[i])
			valid_idx = valid_idx + 1
		end
	end

	collectgarbage()
	print (c.blue"Saving file...")
	torch.save(opt.datafile, provider)
end




-- Load the data
----------------------
print (c.blue"Loading data...")
provider = torch.load(opt.datafile)





-- TODO: move this to an "aux" file
-- method to change the type of the data, models etc 
function cast(t)
   if opt.type == 'cuda' then
      require 'cunn'
      return t:cuda()
   elseif opt.type == 'float' then
      return t:float()
   elseif opt.type == 'cl' then
      require 'clnn'
      return t:cl()
   else
      error('Unknown type '..opt.type)
   end
end

provider.trainData = cast(provider.trainData)
provider.validData = cast(provider.validData)
provider.trainLabel = cast(provider.trainLabel)
provider.validLabel = cast(provider.validLabel)



-- Configure the model
------------------------------------
-- TODO: Parametrize this with width/height of scaled data


print(c.blue '==>' ..' configuring model')
model = nn.Sequential()
model:add(cast(nn.Copy('torch.FloatTensor', torch.type(cast(torch.Tensor())))))
model:add(cast(dofile('models/'..opt.model..'.lua')))
model:get(2).updateGradInput = function(input) return end

if opt.backend == 'cudnn' then
   require 'cudnn'
   cudnn.convert(model:get(2), cudnn)
end

print(model)

-- get the parameters and gradients
parameters, gradParameters = model:getParameters()
parameters = cast(parameters)
gradParameters = cast(gradParameters)

-- set up the confusion matrix
confusion = optim.ConfusionMatrix(10)

-- create the criterion
--criterion = nn.CrossEntropyCriterion()
criterion = nn.ClassNLLCriterion()
criterion = criterion:float()
criterion = cast(criterion)

-- set up the optimizer parameters
optimState = {
  learningRate = opt.learningRate,
  weightDecay = opt.weightDecay,
  momentum = opt.momentum,
  learningRateDecay = opt.learningRateDecay,
}




-- Training function
---------------------------------------------

function train()
	model:training()
	epoch = epoch or 1
	
	-- drop learning rate every "epoch_step" epochs
	if epoch % opt.epoch_step == 0 then optimState.learningRate = optimState.learningRate/5 end
	
	-- update on progress
	print(c.blue '==>'.." Traioning epoch # " .. epoch .. ' [batchSize = ' .. opt.batchSize .. ']')

	local targets = cast(torch.FloatTensor(opt.batchSize))
	local indices = torch.randperm(provider.trainData:size(1)):long():split(opt.batchSize)

	local tic = torch.tic()
	-- train on each batch
	for t,v in ipairs(indices) do
		-- update progress
	    	xlua.progress(t, #indices)

		if v:size(1) ~= opt.batchSize then
			break
		end
		-- set up batch
    		local inputs = provider.trainData:index(1,v)
	    	-- TODO figure out if this was a bad move
		-- targets:copy(provider.trainLabel:index(1,v))
		local targets = provider.trainLabel:index(1,v)
		-- evaluation function
	    	local feval = function(x)
      			if x ~= parameters then parameters:copy(x) end      
      			gradParameters:zero()
	
      			local outputs = model:forward(inputs)
      			local f = criterion:forward(outputs, targets)
      			local df_do = criterion:backward(outputs, targets)
	
      			model:backward(inputs, df_do)
      			confusion:batchAdd(outputs, targets)
      			
      			-- return criterion output and gradient of the parameters
      			return f,gradParameters
    		end
	
		-- one iteration of the optimizer
    	optim.sgd(feval, parameters, optimState)
	end


	-- update confusion matrix
	confusion:updateValids()
	print(('Train accuracy: '..c.cyan'%.2f'..' %%\t time: %.2f s'):format(
    	confusion.totalValid * 100, torch.toc(tic)))

	train_acc = confusion.totalValid * 100
	confusion:zero()	
	epoch = epoch + 1
end



-- Validate function
----------------------
function validate()
	model:evaluate()
	print(c.blue '==>'.." validating")
	local bs = opt.batchSize
	for i=1,provider.validData:size(1),bs do
		if i + bs > provider.validData:size(1)-1 then
			bs = provider.validData:size(1)-i+1
		end
		local outputs = model:forward(provider.validData:narrow(1,i,bs))
    	confusion:batchAdd(outputs, provider.validLabel:narrow(1,i,bs))
  	end

	confusion:updateValids()
  	print(('Valid accuracy: '..c.cyan'%.2f'):format(confusion.totalValid * 100))
    print(confusion)
  	confusion:zero()
end


-- Main Loop
for i = 1,opt.max_epoch do

	-- train one epoch
	train()

	-- validate 
	validate()

  	--[[ save model every 10 epochs
	-- TODO enable this
  	if epoch % 10 == 0 then
    	local filename = paths.concat(opt.save, 'model.net')
    	print('==> saving model to '..filename)
    	torch.save(filename, model:clearState())
  	end]]
 end




