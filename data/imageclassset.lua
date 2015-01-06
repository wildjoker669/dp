local ffi = require 'ffi'
local gm = require 'graphicsmagick'
------------------------------------------------------------------------
--[[ ImageClassSet ]]--
-- A DataSet for image classification in a flat folder structure :
-- [data_path]/[class]/[imagename].JPEG  (folder-name is class-name)
-- Optimized for extremely large datasets (14 million images+).
-- Tested only on Linux (as it uses command-line linux utilities to 
-- scale up to 14 million+ images)
------------------------------------------------------------------------
local ImageClassSet, parent = torch.class("dp.ImageClassSet", "dp.DataSet")

function ImageClassSet:__init(config)
   assert(type(config) == 'table', "Constructor requires key-value arguments")
   local args, data_path, load_size, which_set, sample_size, 
      sampling_mode, carry, verbose = xlua.unpack(
      {config},
      'ImageClassSet', 
      'A DataSet for images in a flat folder structure',
      {arg='data_path', type='table | string', req=true,
       help='one or many paths of directories with images'},
      {arg='load_size', type='table', req=true,
       help='a size to load the images to, initially'},
      {arg='which_set', type='string', default='train',
       help='"train", "valid" or "test" set'},
      {arg='sample_size', type='table',
       help='a consistent sample size to resize the images'},
      {arg='sampling_mode',type='string', default = 'balanced',
       help='Sampling mode: random | balanced '},
      {arg='carry', type='dp.Carry',
       help='An object store that is carried (passed) around the '..
       'network during a propagation.'},
      {arg='verbose', type='boolean', default=true,
       help='display verbose messages'}
   )
   self:setWhichSet(which_set)
   self._load_size = load_size
   self._sample_size = sample_size or self._load_size
   self._sampling_mode = sampling_mode
   self._carry = carry or dp.Carry()
   self._verbose = verbose   
   self._data_path = type(data_path) == 'string' and {data_path} or data_path
   
   -- find class names
   self._classes = {}
   -- loop over each paths folder, get list of unique class names, 
   -- also store the directory paths per class
   -- for each class, 
   local classPaths = {}
   local classes = {}
   for k,path in ipairs(self._data_path) do
      for class in lfs.dir(path) do
         local dirpath = paths.concat(path, class)
         if #class > 2 and paths.dirp(dirpath) and not classes[class] then
            local idx = classes[class]
            if not idx then
               table.insert(self._classes, class)
               idx = #self._classes
               classes[class] = idx
               classPaths[idx] = {}
            end
            if not _.find(classPaths[idx], dirpath) then
               table.insert(classPaths[idx], dirpath)
            end
         end
      end
   end
   if self._verbose then
      print("found " .. #self._classes .. " classes")
   end
   
   self._classIndices = classes
   
   -- define command-line tools, try your best to maintain OSX compatibility
   local wc = 'wc'
   local cut = 'cut'
   local find = 'find'
   if jit.os == 'OSX' then
      wc = 'gwc'
      cut = 'gcut'
      find = 'gfind'
   end
   
   ---------------------------------------------------------------------
   -- Options for the GNU find command
   local extensionList = {'jpg', 'png','JPG','PNG','JPEG', 'ppm', 'PPM', 'bmp', 'BMP'}
   local findOptions = ' -iname "*.' .. extensionList[1] .. '"'
   for i=2,#extensionList do
      findOptions = findOptions .. ' -o -iname "*.' .. extensionList[i] .. '"'
   end

   -- find the image path names
   self.imagePath = torch.CharTensor()  -- path to each image in dataset
   self.imageClass = torch.LongTensor() -- class index of each image (class index in self.classes)
   self.classList = {}                  -- index of imageList to each image of a particular class
   self.classListSample = self.classList -- the main list used when sampling data
   
   if self._verbose then
      print('running "find" on each class directory, and concatenate all' 
         .. ' those filenames into a single file containing all image paths for a given class')
   end
   -- so, generates one file per class
   local classFindFiles = {}
   for i=1,#self._classes do
      classFindFiles[i] = os.tmpname()
   end
   local combinedFindList = os.tmpname();
   
   local tmpfile = os.tmpname()
   local tmphandle = assert(io.open(tmpfile, 'w'))
   -- iterate over classes
   for i, class in ipairs(self._classes) do
      -- iterate over classPaths
      for j,path in ipairs(classPaths[i]) do
         local command = find .. ' "' .. path .. '" ' .. findOptions 
            .. ' >>"' .. classFindFiles[i] .. '" \n'
         tmphandle:write(command)
      end
   end
   io.close(tmphandle)
   os.execute('bash ' .. tmpfile)
   os.execute('rm -f ' .. tmpfile)
   
   if self._verbose then
      print('now combine all the files to a single large file')
   end
   local tmpfile = os.tmpname()
   local tmphandle = assert(io.open(tmpfile, 'w'))
   -- concat all finds to a single large file in the order of self._classes
   for i=1,#self._classes do
      local command = 'cat "' .. classFindFiles[i] .. '" >>' .. combinedFindList .. ' \n'
      tmphandle:write(command)
   end
   io.close(tmphandle)
   os.execute('bash ' .. tmpfile)
   os.execute('rm -f ' .. tmpfile)
   
   ---------------------------------------------------------------------
   if self._verbose then
      print('loading concatenated list of sample paths to self.imagePath')
   end
   local maxPathLength = tonumber(sys.fexecute(wc .. " -L '" 
                                                  .. combinedFindList .. "' |" 
                                                  .. cut .. " -f1 -d' '")) + 1
   local length = tonumber(sys.fexecute(wc .. " -l '" 
                                           .. combinedFindList .. "' |" 
                                           .. cut .. " -f1 -d' '"))
   assert(length > 0, "Could not find any image file in the given input paths")
   assert(maxPathLength > 0, "paths of files are length 0?")
   self.imagePath:resize(length, maxPathLength):fill(0)
   local s_data = self.imagePath:data()
   local count = 0
   for line in io.lines(combinedFindList) do
      ffi.copy(s_data, line)
      s_data = s_data + maxPathLength
      if self._verbose and count % 10000 == 0 then 
         xlua.progress(count, length) 
      end
      count = count + 1
   end

   self._n_sample = self.imagePath:size(1)
   ---------------------------------------------------------------------
   if self._verbose then
      print(self._n_sample ..  ' samples found.')
      print('Updating classList and imageClass appropriately')
   end
   self.imageClass:resize(self._n_sample)
   local runningIndex = 0
   for i=1,#self._classes do
      if self.verbose then xlua.progress(i, #(self.classes)) end
      local length = tonumber(sys.fexecute(wc .. " -l '" 
                                              .. classFindFiles[i] .. "' |" 
                                              .. cut .. " -f1 -d' '"))
      if length == 0 then
         error('Class has zero samples')
      else
         self.classList[i] = torch.linspace(runningIndex + 1, runningIndex + length, length):long()
         self.imageClass[{{runningIndex + 1, runningIndex + length}}]:fill(i)
      end
      runningIndex = runningIndex + length
   end

   ----------------------------------------------------------------------
   -- clean up temporary files
   if self._verbose then
      print('Cleaning up temporary files')
   end
   local tmpfilelistall = ''
   for i=1,#(classFindFiles) do
      tmpfilelistall = tmpfilelistall .. ' "' .. classFindFiles[i] .. '"'
      if i % 1000 == 0 then
         os.execute('rm -f ' .. tmpfilelistall)
         tmpfilelistall = ''
      end
   end
   os.execute('rm -f '  .. tmpfilelistall)
   os.execute('rm -f "' .. combinedFindList .. '"')
end

-- builds a batch (factory method)
-- reuses the inputs and targets (so don't modify them)
function ImageClassSet:batch(batch_size)
   return self:sub(1, batch_size)
end

-- converts a table of samples (and corresponding labels) to a clean tensor
function ImageClassSet:tableToOutput(dataTable, scalarTable)
   local data, scalarLabels, labels
   local quantity = #scalarTable
   local samplesPerDraw
   if dataTable[1]:dim() == 3 then samplesPerDraw = 1
   else samplesPerDraw = dataTable[1]:size(1) end
   if quantity == 1 and samplesPerDraw == 1 then
      data = dataTable[1]
      scalarLabels = scalarTable[1]
      labels = torch.LongTensor(#(self.classes)):fill(-1)
      labels[scalarLabels] = 1
   else
      data = torch.Tensor(quantity * samplesPerDraw, 
                          self.sampleSize[1], self.sampleSize[2], self.sampleSize[3])
      scalarLabels = torch.LongTensor(quantity * samplesPerDraw)
      labels = torch.LongTensor(quantity * samplesPerDraw, #(self.classes)):fill(-1)
      for i=1,#dataTable do
         data[{{i, i+samplesPerDraw-1}}]:copy(dataTable[i])
         scalarLabels[{{i, i+samplesPerDraw-1}}]:fill(scalarTable[i])
         labels[{{i, i+samplesPerDraw-1},{scalarTable[i]}}]:fill(1)
      end
   end   
   return data, scalarLabels, labels
end

function ImageClassSet:sub(batch, start, stop)
   if (not batch) or (not stop) then 
      if batch then
         stop = start
         start = batch
      end
      return dp.Batch{
         which_set=self:whichSet(), epoch_size=self:nSample(),
         inputs=self:inputs():sub(start, stop),
         targets=self:targets() and self:targets():sub(start, stop),
         carry=self:carry() and self:carry():sub(start, stop)
      }    
   end
   assert(batch.isBatch, "Expecting dp.Batch at arg 1")
   
   self:inputs():sub(batch:inputs(), start, stop)
   if self:targets() then
      self:targets():sub(batch:targets(), start, stop)
   end
   self:carry():sub(batch:carry(), start, stop)
   return batch  
   
   assert(quantity > 0)
   -- now that indices has been initialized, get the samples
   local dataTable = {}
   local scalarTable = {}
   for idx=start,stop do
      -- load the sample
      local imgpath = ffi.string(torch.data(self.imagePath[idx]]))
      out = self:sampleHookTest(imgpath)
      table.insert(dataTable, out)
      table.insert(scalarTable, self.imageClass[idx])      
   end
   local data, scalarLabels, labels = self:tableToOutput(dataTable, scalarTable)
   return data, scalarLabels, labels
end

function ImageClassSet:index(batch, indices)
   if (not batch) or (not indices) then 
      indices = indices or batch
      return dp.Batch{
         which_set=self:whichSet(), epoch_size=self:nSample(),
         inputs=self:inputs():index(indices),
         targets=self:targets() and self:targets():index(indices),
         carry=self:carry() and self:carry():index(indices)
      }
   end
   assert(batch.isBatch, "Expecting dp.Batch at arg 1")
   self:inputs():index(batch:inputs(), indices)
   if self:targets() then
      self:targets():index(batch:targets(), indices)
   end
   self:carry():index(batch:carry(), indices)
   return batch
end

function ImageClassSet:loadImage(path)
   -- https://github.com/clementfarabet/graphicsmagick#gmimage
   local out = gm.Image()
   out:load(path, self.loadSize[3], self.loadSize[2])
   :size(self.sampleSize[3], self.sampleSize[2])
   out = out:toTensor('float','RGB','DHW')
   return out
end




-- size(), size(class)
function ImageClassSet:size(class, list)
   list = list or self.classList
   if not class then
      return self.numSamples
   elseif type(class) == 'string' then
      return list[self.classIndices[class]]:size(1)
   elseif type(class) == 'number' then
      return list[class]:size(1)
   end
end


-- getByClass
function ImageClassSet:getByClass(class)
   local index = math.ceil(torch.uniform() * self.classListSample[class]:nElement())
   local imgpath = ffi.string(torch.data(self.imagePath[self.classListSample[class][index]]))
   return self:sampleHookTrain(imgpath)
end


-- sampler, samples from the training set.
function ImageClassSet:sample(quantity)
   if self.split == 0 then 
      error('No training mode when split is set to 0') 
   end
   quantity = quantity or 1
   local dataTable = {}
   local scalarTable = {}   
   for i=1,quantity do
      local class = torch.random(1, #self.classes)
      local out = self:getByClass(class)
      table.insert(dataTable, out)
      table.insert(scalarTable, class)      
   end
   local data, scalarLabels, labels = tableToOutput(self, dataTable, scalarTable)
   return data, scalarLabels, labels      
end

function ImageClassSet:get(i1, i2)
   local indices, quantity
   if type(i1) == 'number' then
      if type(i2) == 'number' then -- range of indices
         indices = torch.range(i1, i2); 
         quantity = i2 - i1 + 1;
      else -- single index 
         indices = {i1}; quantity = 1 
      end 
   elseif type(i1) == 'table' then
      indices = i1; quantity = #i1;         -- table
   elseif (type(i1) == 'userdata' and i1:nDimension() == 1) then
      indices = i1; quantity = (#i1)[1];    -- tensor
   else
      error('Unsupported input types: ' .. type(i1) .. ' ' .. type(i2))      
   end
   assert(quantity > 0)
   -- now that indices has been initialized, get the samples
   local dataTable = {}
   local scalarTable = {}
   for i=1,quantity do
      -- load the sample
      local imgpath = ffi.string(torch.data(self.imagePath[indices[i]]))
      out = self:sampleHookTest(imgpath)
      table.insert(dataTable, out)
      table.insert(scalarTable, self.imageClass[indices[i]])      
   end
   local data, scalarLabels, labels = tableToOutput(self, dataTable, scalarTable)
   return data, scalarLabels, labels
end

function ImageClassSet:test(quantity)
   if self.split == 100 then
      error('No test mode when you are not splitting the data')
   end
   local i = 1
   local n = self.testIndicesSize
   local qty = quantity or 1
   return function ()
      if i+qty-1 <= n then 
         local data, scalarLabelss, labels = self:get(i, i+qty-1)
         i = i + qty
         return data, scalarLabelss, labels
      end
   end
end
