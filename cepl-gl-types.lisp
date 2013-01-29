(in-package :cepl-gl)


;; ARGHHHHHHHHHHHHHHHHHHHHHHHHH
;; GOD DAMN ARRAY OF VEC3
;; mem-aref will be wrong god damnit
;; ARGHHHHHHHHhhhhh GRRRR aRGRRRG 

;; Ok so we do need foreign helper types
;; create structs automatically from
;; varjo::*glsl-component-counts* 
;; Use in returning arrays of slot types 
;; in combination with gl-arrays, this 
;; gives us easy access and correct indexing

;; (defglstruct new-type
;;   (position :vec3)
;;   (color :vec4)
;;   (depth (:float 3))
;;   (test :int :normalised t ))

(defun agg-type-helper-name (type)
  (utils:symb 'cgl- (varjo:type-principle type)))

(defmacro make-foreign-helper-types ()
  `(progn 
     ,@(loop for (type . len) in 
	     varjo::*glsl-component-counts*
	     collect 
	     (let ((ftype (varjo:flesh-out-type type))) 
	       `(defcstruct ,(utils:symb 'cgl- type)
		  (components ,(varjo:type-component-type
				ftype)
			      :count ,(varjo:type-component-count
				       ftype)))))))

(make-foreign-helper-types)

;;------------------------------------------------------------
;; Homeless functions

(defgeneric dpopulate (array-type gl-array data)
  (:documentation 
   "This is the function that actually does the work in the 
    destructuring populate"))

(defgeneric gl-assign-attrib-pointers (type attrib-num &optional pointer-offset))

(defun glsl-struct-p (type-symb)
  (when (and (glsl-type-p type-symb)
             (not (glsl-aggregrate-type-p type-symb))) 
    t))

(defun foreign-type-index (type index)
  (* (cffi:foreign-type-size type)
     index))

;;------------------------------------------------------------

(defun make-aggregate-getter (type-name slot-name slot-type)
  (let ((len (varjo:type-component-count slot-type))
	(core-type (varjo:type-component-type slot-type))
	(slot-pointer (gensym "slot-pointer")))
    `(let ((,slot-pointer (foreign-slot-value pointer ',type-name
					      ',slot-name)))
       (make-array ,len
		   :initial-contents
		   (list ,@(loop 
			     :for i :below len
			     :collect  
			     `(mem-aref ,slot-pointer 
					,core-type ,i)))))))

(defun make-gl-struct-slot-getters (type-name slots) 
  (loop :for (slot-name slot-type) :in slots
     :collect
	`(defun ,(utils:symb type-name '- slot-name) (pointer)
	   ,(cond ((varjo:type-arrayp slot-type) 
		   `(make-glarray 
			:pointer (foreign-slot-pointer 
				   pointer ',type-name ',slot-name)
			:length ,(varjo:type-array-length slot-type)
			:type ',(if (varjo:type-aggregate-p 
				    (varjo:type-principle 
				     slot-type))
				   (agg-type-helper-name slot-type)
				   (varjo:type-principle
				    slot-type))))
		  ((not (varjo:type-built-inp slot-type)) 
		   `(foreign-slot-pointer pointer
					  ',type-name
					  ',slot-name))
		  (t (if (varjo:type-aggregate-p slot-type)
			 (make-aggregate-getter type-name slot-name
						slot-type)
			 `(foreign-slot-value pointer
					      ',type-name
					      ',slot-name)))))))

(defun make-aggregate-setter (type-name slot-name slot-type
			      value)
  (let ((len (varjo:type-component-count slot-type))
	(core-type (varjo:type-component-type slot-type))
	(slot-pointer (gensym "slot-pointer")))
    `(let ((,slot-pointer (foreign-slot-value pointer ',type-name
					      ',slot-name)))
       ,@(loop :for i :below len
	       :collect  
	       `(setf (mem-aref ,slot-pointer ,core-type ,i)
		      (aref ,value ,i))))))

(defun make-gl-struct-slot-setters (type-name slots) 
  (loop :for (slot-name slot-type) :in slots
	:collect
	`(defun (setf ,(utils:symb type-name '- slot-name)) 
	     (value pointer)
	   ,(if (or (varjo:type-arrayp slot-type) 
		    (not (varjo:type-built-inp slot-type)))
		`(error "GLSTRUCT SETTER ERROR: Sorry, you cannot directly set a foreign slot of type array or struct: ~s ~s" value pointer)
		(if (varjo:type-aggregate-p slot-type)
		    (make-aggregate-setter type-name slot-name
					   slot-type 'value)
		    `(setf (foreign-slot-value pointer ',type-name
					       ',slot-name)
			   value))))))


(defun make-gl-struct-dpop (type-name slots)
  (let ((loop-token (gensym "LOOP"))
        (slot-names (mapcar #'slot-name slots)))
    `(defmethod dpopulate ((array-type (eql ',type-name))
                           gl-array
                           data)
       (loop for ,slot-names in data
          for ,loop-token from 0
          do ,@(loop for (slot-name) in slots
                  collect
                    `(setf (,(utils:symb type-name '- slot-name)
                             (aref-gl gl-array ,loop-token))
                           ,slot-name))))))

(defun make-gl-struct-glpull (type-name slots)
  `(defmethod glpull-entry ((array-type (eql ',type-name))
                            gl-array
                            index)
     (list ,@(loop for (slot-name) in slots
                collect
                  `(,(utils:symb type-name '- slot-name)
                     (aref-gl gl-array index))))))

;; This is wrong!
(defun make-gl-struct-attrib-assigner (type-name slots)
  (when (every #'varjo:type-built-inp (mapcar #'slot-type slots))
    (let* ((stride (if (> (length slots) 1)
                       `(cffi:foreign-type-size ',type-name)
                       0))
           (definitions 
	     (loop for (slot-name slot-type normalised) in slots
		   for i from 0
		   :if (varjo:type-aggregate-p
			(varjo:type-principle slot-type)) 
		     :collect 
		   `(%gl:vertex-attrib-pointer
		     (+ attrib-num ,i)
		     ,(* (varjo:type-component-count slot-type)
			 (if (varjo:type-arrayp slot-type)
			     (varjo:type-array-length slot-type)
			     1))
		     ',(varjo:type-component-type slot-type) 
		     ,normalised
		     ,stride
		     (+ (foreign-slot-offset ',type-name
					     ',slot-name)
			pointer-offset))
		   :else :collect
		   `(%gl:vertex-attrib-pointer
		     (+ attrib-num ,i) 
		     ,(if (varjo:type-arrayp slot-type)
			  (varjo:type-array-length slot-type)
			  1)
		     ,(varjo:type-principle slot-type) 
		     ,normalised ,stride
		     (cffi:make-pointer 
		      (+ (foreign-slot-offset ',type-name
					      ',slot-name)
			 pointer-offset))))))
      (when definitions
        `(defmethod gl-assign-attrib-pointers 
	     ((array-type (EQL ',type-name)) attrib-num
	      &optional pointer-offset)
           (declare (ignore array-type))
           ,@definitions)))))

(defun make-cstruct-def (name slots)
  `(defcstruct ,name
       ,@(loop for slot in slots
	       :collect 
	       (list (slot-name slot)
		     (if (varjo:type-aggregate-p 
			  (varjo:type-principle (slot-type slot)))
			 (agg-type-helper-name (slot-type slot))
			 (varjo:type-principle (slot-type slot)))
		     :count (if (varjo:type-arrayp (slot-type slot))
				(varjo:type-array-length 
				 (slot-type slot))
				1)))))

(defun slot-name (slot) (first slot))
(defun slot-type (slot) (second slot))
(defun slot-normalisedp (slot) (third slot))

(defmacro defglstruct (name &body slot-descriptions)
  ;; tidy up the slot definintions
  (let ((slots (loop for slot in slot-descriptions
                  collect (destructuring-bind 
                                (slot-name 
                                 slot-type 
                                 &key (normalised nil) 
                                 &allow-other-keys)
                              slot
                            (list slot-name 
				  (varjo:flesh-out-type slot-type) 
				  normalised)))))
    ;; write the code
    `(progn
       (varjo:vdefstruct ,name
	 ,@(loop for slot in slots
		 collect (subseq slot 0 2)))
       ,(make-cstruct-def name slots)
       ,@(make-gl-struct-slot-getters name slots)
       ,@(make-gl-struct-slot-setters name slots)
       ,(make-gl-struct-dpop name slots)
       ,(make-gl-struct-glpull name slots)
       ,(make-gl-struct-attrib-assigner name slots)
       ',name)))
