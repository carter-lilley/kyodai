#batch_processor.gd
extends RefCounted
class_name BatchProcessor

var _items: Array
var _process_callback: Callable
var _complete_callback: Callable
var _progress_callback: Callable
var _current_index: int = 0
var _success_count: int = 0
var _batch_size: int = 10

func _init(items: Array, process_callback: Callable, complete_callback: Callable, progress_callback: Callable = Callable()):
	_items = items
	_process_callback = process_callback
	_complete_callback = complete_callback
	_progress_callback = progress_callback

func start():
	_current_index = 0
	_success_count = 0
	_process_next()

func _process_next():
	if _current_index >= _items.size():
		_complete_callback.call(_success_count)
		return
	
	var item = _items[_current_index]
	_current_index += 1
	
	_process_callback.call(item, func(success: bool):
		if success:
			_success_count += 1
		
		# Report progress every batch_size items
		if _progress_callback.is_valid() and _current_index % _batch_size == 0:
			_progress_callback.call(_current_index, _items.size())
		
		# Continue processing
		call_deferred("_process_next")
	)
