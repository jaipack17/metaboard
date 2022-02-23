local UserInputService = game:GetService("UserInputService")
local LocalPlayer = game:GetService("Players").LocalPlayer
local Common = game:GetService("ReplicatedStorage").MetaBoardCommon
local Config = require(Common.Config)
local History = require(Common.History)
local DrawingTask = require(Common.DrawingTask)
local GuiPositioning = require(Common.GuiPositioning)
local ClientDrawingTasks
local DrawingTool = require(Common.DrawingTool)
local CanvasState
local Buttons
local Pen = DrawingTool.Pen
local Eraser = DrawingTool.Eraser

local BoardGui
local Canvas

local Drawing = {
	-- mouse state
	---------------
	MouseHeld = false,
	-- pixel coordinates of mouse
	MousePixelPos = nil,

	-- the cursor that follows the mouse position
	Cursor = nil,

	-- drawing pen state
	---------------------
	PenA = nil,
	PenB = nil,

	-- Drawing Mode
	PenMode = nil,

	-- eraser state
	----------------
	Eraser = nil,
	
	EquippedTool = nil,
	
	ReservedTool = nil,

	CurrentTaskObject = nil,

	-- The metatable makes StateByBoard weak, which means it won't hold boards
	-- in memory if they are otherwise ready to be released i.e. they have been
	-- removed from the DataModel.
	StateByBoard = setmetatable({}, {__mode = "k"}),
}
Drawing.__index = Drawing

local function obtainStateFromBoard(board)
	local state = Drawing.StateByBoard[board]
	if not state then
		state = {}
		Drawing.StateByBoard[board] = state

		-- The state doesn't already have a record, so we assume the player is
		-- opening this board for the first time. Let's set to the default
		-- colours.
		local defaultPenAColorObj = board:FindFirstChild("DefaultPenAColor")
		state.penAColor = if defaultPenAColorObj and Drawing.PenA.AllColors[defaultPenAColorObj.Value]
			then Drawing.PenA.AllColors[defaultPenAColorObj.Value]
			else Config.Drawing.Defaults.PenAColor
		local defaultPenBColorObj = board:FindFirstChild("DefaultPenBColor")
		state.penBColor = if defaultPenBColorObj and Drawing.PenB.AllColors[defaultPenBColorObj.Value]
			then Drawing.PenB.AllColors[defaultPenBColorObj.Value]
			else Config.Drawing.Defaults.PenBColor
	end

	return state
end

function Drawing.Init(boardGui)
	BoardGui = boardGui

	Canvas = BoardGui.Canvas

	CanvasState = require(script.Parent.CanvasState)
	Buttons = require(script.Parent.Buttons)

	Drawing.PenA = Pen.new(Config.Drawing.Defaults.PenAColor, Config.Drawing.Defaults.PenAThicknessYScale, BoardGui.Toolbar.Pens.PenAButton)
	Drawing.PenB = Pen.new(Config.Drawing.Defaults.PenBColor, Config.Drawing.Defaults.PenBThicknessYScale, BoardGui.Toolbar.Pens.PenBButton)

	local colorsA = {}
	local colorsB = {}
	for _, colorButton in ipairs(boardGui.Toolbar.Colors:GetChildren()) do
		if colorButton:IsA("TextButton") and colorButton.Name ~= "SelectShade" then 
			colorsA[colorButton.Name] = colorButton.BackgroundColor3
			colorsB[colorButton.Name] = colorButton.BackgroundColor3
		end
	end
	
	Drawing.PenA:SetAllColors(colorsA)
	Drawing.PenB:SetAllColors(colorsB)
	
	Drawing.PenMode = "FreeHand"

	ClientDrawingTasks = require(script.Parent.ClientDrawingTasks)

	Drawing.Eraser = Eraser.new(Config.Drawing.Defaults.EraserThicknessYScale, BoardGui.Toolbar.Erasers.SmallButton)

	Drawing.EquippedTool = Drawing.PenA
	Drawing.ReservedTool = Drawing.Eraser

	Drawing.CursorGui = Instance.new("ScreenGui")
	Drawing.CursorGui.Name = "CursorGui"
	Drawing.CursorGui.DisplayOrder = 2147483647
	Drawing.CursorGui.IgnoreGuiInset = true
	Drawing.CursorGui.ResetOnSpawn = false
	
	Drawing.CursorGui.Enabled = false
	Drawing.CursorGui.Parent = BoardGui

	Drawing.InitCursor(Drawing.CursorGui)

	Canvas.Button.MouseButton1Down:Connect(function(x,y)
		if not CanvasState.HasWritePermission then return end

		Drawing.UpdateCursor(x,y)
		Drawing.Cursor.Visible = true
		Drawing.ToolDown(x,y)
	end)

	Canvas.Button.MouseMoved:Connect(function(x,y)
		if not CanvasState.HasWritePermission then return end

		Drawing.UpdateCursor(x,y)
		Drawing.ToolMoved(x,y)
	end)

	Canvas.Button.MouseEnter:Connect(function(x,y)
		if not CanvasState.HasWritePermission then return end

		Drawing.UpdateCursor(x,y)
		Drawing.Cursor.Visible = true
	end)
	
	Canvas.Button.MouseLeave:Connect(function(x,y)
		if not CanvasState.HasWritePermission then return end

		if Drawing.MouseHeld then
			Drawing.ToolLift(x, y)
		end
		Drawing.MouseHeld = false
		Drawing.Cursor.Visible = false
	end)
	
	UserInputService.InputEnded:Connect(function(input, gp)
		if not CanvasState.HasWritePermission then return end
		
		if Drawing.MouseHeld then
			Drawing.ToolLift(input.Position.X, input.Position.Y + 36)
		end
		Drawing.MouseHeld = false
	end)

end

function Drawing.SetEquippedToolColor(color)
	Drawing.EquippedTool:SetColor(color)
	local state = obtainStateFromBoard(CanvasState.EquippedBoard)
	if Drawing.EquippedTool == Drawing.PenA then
		state.penAColor = color
	else
		state.penBColor = color
	end
end

function Drawing.OnBoardOpen(board)
	local state = obtainStateFromBoard(board)

	Drawing.PenA:SetColor(state.penAColor)
	Drawing.PenB:SetColor(state.penBColor)

	Buttons.SyncPenButton(Drawing.PenA.GuiButton, Drawing.PenA)
	Buttons.SyncPenButton(Drawing.PenB.GuiButton, Drawing.PenB)

	Drawing.CursorGui.Enabled = true
end

function Drawing.OnBoardClose(board)
	Drawing.CursorGui.Enabled = false
end

function Drawing.WithinBounds(x,y, thicknessYScale)
	local leftBuffer = (x - Canvas.AbsolutePosition.X)/Canvas.AbsoluteSize.Y
	local rightBuffer = (Canvas.AbsolutePosition.X + Canvas.AbsoluteSize.X - x)/Canvas.AbsoluteSize.Y
	local upBuffer = (y - (Canvas.AbsolutePosition.Y + 36))/Canvas.AbsoluteSize.Y
	local downBuffer = ((Canvas.AbsolutePosition.Y + Canvas.AbsoluteSize.Y + 36) - y)/Canvas.AbsoluteSize.Y

	return
		leftBuffer >= thicknessYScale/2 and
		rightBuffer >= thicknessYScale/2 and
		upBuffer >= thicknessYScale/2 and
		downBuffer >= thicknessYScale/2
end

function Drawing.ToolDown(x,y)
	Buttons.SyncShadeFrame(false, "")
	Drawing.MouseHeld = true

	local canvasPos = CanvasState.GetScalePositionOnCanvas(Vector2.new(x,y))

	local playerHistory = BoardGui.History:FindFirstChild(LocalPlayer.UserId)
	if playerHistory == nil then
		playerHistory = History.Init(LocalPlayer)
		playerHistory.Parent = BoardGui.History
	end

	if Drawing.EquippedTool.ToolType == "Eraser" then
		local eraseObjectId = Config.GenerateUUID()
		local eraseObject = Instance.new("Folder")
		eraseObject.Name = eraseObjectId
		eraseObject.Parent = BoardGui.Erases

		Drawing.CurrentTaskObject = eraseObject

		ClientDrawingTasks.Erase.Init(eraseObject, LocalPlayer.UserId, Drawing.EquippedTool.ThicknessYScale, canvasPos)

		
		History.ForgetFuture(playerHistory)
		History.RecordTaskToHistory(playerHistory, eraseObject)

		DrawingTask.InitRemoteEvent:FireServer(
			CanvasState.EquippedBoard,
			"Erase",
			eraseObjectId,
			LocalPlayer.UserId,
			Drawing.EquippedTool.ThicknessYScale,
			canvasPos
		)
	else
		if not Drawing.WithinBounds(x,y, Drawing.EquippedTool.ThicknessYScale) then
			return
		end

		if Drawing.EquippedTool.ToolType == "Pen" then
			local curveId = Config.GenerateUUID()
			local curve = CanvasState.CreateCurve(CanvasState.EquippedBoard, curveId)
			Drawing.CurrentTaskObject = curve

			ClientDrawingTasks[Drawing.PenMode].Init(
				curve,
				LocalPlayer.UserId,
				Drawing.EquippedTool.ThicknessYScale,
				Drawing.EquippedTool.Color,
				CanvasState.EquippedBoard.CurrentZIndex.Value,
				canvasPos
			)

			History.ForgetFuture(playerHistory)
			History.RecordTaskToHistory(playerHistory, curve)

			DrawingTask.InitRemoteEvent:FireServer(
				CanvasState.EquippedBoard,
				Drawing.PenMode,
				curveId,
				LocalPlayer.UserId,
				Drawing.EquippedTool.ThicknessYScale,
				Drawing.EquippedTool.Color,
				CanvasState.EquippedBoard.CurrentZIndex.Value,
				canvasPos
			)
		end
	end

	Buttons.SyncUndoButton(playerHistory)
	Buttons.SyncRedoButton(playerHistory)

	Drawing.MousePixelPos = Vector2.new(x, y)
end

function Drawing.ToolMoved(x,y)
	if Drawing.MouseHeld then

		local newCanvasPos = CanvasState.GetScalePositionOnCanvas(Vector2.new(x, y))

		if Drawing.EquippedTool.ToolType == "Eraser" then
			ClientDrawingTasks.Erase.Update(Drawing.CurrentTaskObject, newCanvasPos)
			DrawingTask.UpdateRemoteEvent:FireServer(CanvasState.EquippedBoard, "Erase", Drawing.CurrentTaskObject.Name, newCanvasPos)
		else
			assert(Drawing.EquippedTool.ToolType == "Pen")

			if not Drawing.WithinBounds(x,y, Drawing.EquippedTool.ThicknessYScale) then
				Drawing.MousePixelPos = Vector2.new(x, y)
				return
			end

			-- Simple palm rejection
			if UserInputService.TouchEnabled then
				local diff = Vector2.new(x,y) - Drawing.MousePixelPos
				if diff.Magnitude > Config.Drawing.MaxLineLengthTouch then
					return
				end
				--if diff.Magnitude < Config.Drawing.MinLineLengthTouch then
				--	print("[metaboard] ToolMoved palm rejection, line length "..tostring(diff.Magnitude))
				--	return
				--end
			end

			ClientDrawingTasks[Drawing.PenMode].Update(Drawing.CurrentTaskObject, newCanvasPos)
			DrawingTask.UpdateRemoteEvent:FireServer(CanvasState.EquippedBoard, Drawing.PenMode, Drawing.CurrentTaskObject.Name, newCanvasPos)

		end

		Drawing.MousePixelPos = Vector2.new(x, y)
	end
end

function Drawing.ToolLift(x,y)

	Drawing.MouseHeld = false
	Drawing.MousePixelPos = Vector2.new(x,y)
	
	if Drawing.EquippedTool == "Eraser" then
		ClientDrawingTasks.Erase.Finish(Drawing.CurrentTaskObject)
		DrawingTask.FinishRemoteEvent:FireServer(CanvasState.EquippedBoard, "Erase", Drawing.CurrentTaskObject.Name)
	elseif Drawing.EquippedTool.ToolType == "Pen" then
		-- Simple palm rejection
		if UserInputService.TouchEnabled then
			local diff = Vector2.new(x,y) - Drawing.MousePixelPos
			if diff.Magnitude < Config.Drawing.MinLineLengthTouch then
				print("[metaboard] ToolLift palm rejection line length "..tostring(diff.Magnitude))
			end
		end

		-- BUG: the next line has crashed with "attempt to call nil value"
		ClientDrawingTasks[Drawing.PenMode].Finish(Drawing.CurrentTaskObject)
		DrawingTask.FinishRemoteEvent:FireServer(CanvasState.EquippedBoard, Drawing.PenMode, Drawing.CurrentTaskObject.Name)
	end

	local playerHistory = BoardGui.History:FindFirstChild(LocalPlayer.UserId)
	if playerHistory then
		History.ForgetOldestUntilSize(playerHistory, Config.History.MaximumSize,
			function(oldTaskObject)
				-- BUG: this has crashed with drawingTask = nil
				local drawingTask = ClientDrawingTasks[oldTaskObject:GetAttribute("TaskType")]
				if drawingTask then
					drawingTask.Commit(oldTaskObject)
				end
			end)
	end
end


-- Draw/update the cursor for a player's tool on the Gui
function Drawing.InitCursor(cursorGui)
	Drawing.Cursor = Instance.new("Frame")
	Drawing.Cursor.Name = LocalPlayer.Name.."Cursor"
	Drawing.Cursor.Rotation = 0
	Drawing.Cursor.SizeConstraint = Enum.SizeConstraint.RelativeYY
	Drawing.Cursor.AnchorPoint = Vector2.new(0.5,0.5)
	
	-- Make cursor circular
	local UICorner = Instance.new("UICorner")
	UICorner.CornerRadius = UDim.new(0.5,0)
	UICorner.Parent = Drawing.Cursor

	-- Add outline
	local UIStroke = Instance.new("UIStroke")
	UIStroke.Thickness = 1
	UIStroke.Color = Color3.new(0,0,0)
	UIStroke.Parent = Drawing.Cursor

	Drawing.Cursor.Parent = cursorGui
end

function Drawing.UpdateCursor(x,y)
	-- Reposition cursor to new position (should be given with Scale values)
	Drawing.Cursor.Position = GuiPositioning.PositionFromPixel(x, y, Drawing.CursorGui.IgnoreGuiInset)
	
	-- Configure Drawing.Cursor appearance based on tool type
	if Drawing.EquippedTool.ToolType == "Pen" then
		Drawing.Cursor.Size =
			UDim2.new(0, Drawing.EquippedTool.ThicknessYScale * Canvas.AbsoluteSize.Y,
								0, Drawing.EquippedTool.ThicknessYScale * Canvas.AbsoluteSize.Y)
		Drawing.Cursor.BackgroundColor3 = Drawing.EquippedTool.Color
		Drawing.Cursor.BackgroundTransparency = 0.5
	elseif Drawing.EquippedTool.ToolType == "Eraser" then
		Drawing.Cursor.Size = UDim2.new(0, Drawing.EquippedTool.ThicknessYScale * Canvas.AbsoluteSize.Y,
														0, Drawing.EquippedTool.ThicknessYScale * Canvas.AbsoluteSize.Y)
		Drawing.Cursor.BackgroundColor3 = Color3.new(1, 1, 1)
		Drawing.Cursor.BackgroundTransparency = 0.5
	end
end

-- Perform the Douglas-Peucker algorithm on a polyline given as an array
-- of points. Instead of returning a new polyline, this function sets
-- all of the removed points to nil
function Drawing.DouglasPeucker(points, startIndex, stopIndex, epsilon)
	
	if stopIndex - startIndex + 1 <= 2 then return end

	local startPoint = points[startIndex]
	local stopPoint = points[stopIndex]

	local maxPerp = nil
	local maxPerpIndex = nil
	
	for i = startIndex+1, stopIndex-1 do
		-- Get the length of the perpendicular vector between points[i] and the line through startPoint and stopPoint
		local perp = math.abs((points[i] - startPoint).Unit:Cross((startPoint-stopPoint).Unit) * ((points[i] - startPoint).Magnitude))
		if maxPerp == nil or perp > maxPerp then
			maxPerp = perp
			maxPerpIndex = i
		end
	end

	if maxPerp > epsilon then
		Drawing.DouglasPeucker(points, startIndex, maxPerpIndex, epsilon)
		Drawing.DouglasPeucker(points, maxPerpIndex, stopIndex, epsilon)
	else
		for i = startIndex+1, stopIndex-1 do
			points[i] = nil
		end
	end
end


return Drawing
